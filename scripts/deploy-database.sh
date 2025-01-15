#!/bin/bash

# Input variables
DB_NAME=$1                  # Database name (required)
DB_TYPE=$2                  # Database type (required)
DB_VERSION=$3               # Database version (required)
NAMESPACE=$4                # Namespace (required)
DB_PASSWORD=$5              # Database password (required for MySQL)
DB_USERNAME=${6:-defaultUser} # Database username (default for MySQL)
DOMAIN_NAME=$7              # Optional domain name for Ingress
STORAGE_SIZE=${8:-1Gi}      # Default storage size
PORT=${9:-30000}           # Default port for NodePort (optional, default is 30000)

# Validate required parameters
if [ -z "$DB_NAME" ] || [ -z "$DB_TYPE" ] || [ -z "$DB_VERSION" ] || [ -z "$NAMESPACE" ]; then
    echo "❌ Error: Missing required parameters"
    echo "Usage: $0 DB_NAME DB_TYPE DB_VERSION NAMESPACE [DB_PASSWORD] [DB_USERNAME] [DOMAIN_NAME] [STORAGE_SIZE] [PORT]"
    echo "Example: $0 mydb mysql 8.0 my-namespace mysecretpass dbuser"
    exit 1
fi

if [ "$NAMESPACE" = "default" ]; then
    echo "❌ Error: Using 'default' namespace is not allowed"
    echo "Please specify a different namespace"
    exit 1
fi

# Set MySQL-specific defaults
if [ "${DB_TYPE}" == "mysql" ]; then
    DB_PASSWORD=${DB_PASSWORD:-rootpassword}   # Default MySQL root password
    DB_USERNAME=${DB_USERNAME:-defaultuser}    # Default MySQL username
fi

# Function to validate unique deployment
validate_unique_deployment() {
    echo "🔍 Checking for conflicts..."
    
    # Check if database name exists in namespace
    if kubectl get pods -n ${NAMESPACE} -l app=${DB_NAME} 2>/dev/null | grep -q "${DB_NAME}"; then
        echo "❌ Database '${DB_NAME}' already exists in namespace '${NAMESPACE}'"
        exit 1
    fi
}

# Function to set database-specific configurations
configure_database() {
    case ${DB_TYPE} in
        "mysql")
            DB_IMAGE="mysql:${DB_VERSION}"
            ENV_ROOT_PASSWORD_VAR="MYSQL_ROOT_PASSWORD"
            ENV_USERNAME_VAR="MYSQL_USER"
            ENV_PASSWORD_VAR="MYSQL_PASSWORD"
            ENV_DB_VAR="MYSQL_DATABASE"
            DB_PORT=3306
            VOLUME_MOUNT_PATH="/var/lib/mysql"
            READINESS_CMD="mysqladmin ping -h localhost -u${DB_USERNAME} -p${DB_PASSWORD}"
            ;;
        "postgres")
            DB_IMAGE="postgres:${DB_VERSION}"
            ENV_USERNAME_VAR="POSTGRES_USER"
            ENV_PASSWORD_VAR="POSTGRES_PASSWORD"
            ENV_DB_VAR="POSTGRES_DB"
            DB_PORT=5432
            VOLUME_MOUNT_PATH="/var/lib/postgresql/data"
            READINESS_CMD="pg_isready -U ${DB_USERNAME} -d ${DB_NAME}"
            ;;
        "mongodb")
            DB_IMAGE="mongo:${DB_VERSION}"
            ENV_USERNAME_VAR="MONGO_INITDB_ROOT_USERNAME"
            ENV_PASSWORD_VAR="MONGO_INITDB_ROOT_PASSWORD"
            ENV_DB_VAR="MONGO_INITDB_DATABASE"
            DB_PORT=27017
            VOLUME_MOUNT_PATH="/data/db"
            READINESS_CMD="mongosh --eval 'db.runCommand({ ping: 1 })'"
            ;;
        *)
            echo "❌ Unsupported database type. Use postgres, mysql, or mongodb."
            exit 1
            ;;
    esac
}

# Create namespace and secrets
create_namespace_resources() {
    # Create namespace if not exists
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    # Label namespace for network policies
    kubectl label namespace ${NAMESPACE} name=${NAMESPACE} --overwrite

    # Create secret for database credentials
    if [ "${DB_TYPE}" == "mysql" ]; then
        kubectl create secret generic ${DB_NAME}-secret \
            --namespace=${NAMESPACE} \
            --from-literal=MYSQL_ROOT_PASSWORD=${DB_PASSWORD} \
            --from-literal=MYSQL_USER=${DB_USERNAME} \
            --from-literal=MYSQL_PASSWORD=${DB_PASSWORD} \
            --from-literal=MYSQL_DATABASE=${DB_NAME} \
            --dry-run=client -o yaml | kubectl apply -f -
    elif [ "${DB_TYPE}" == "postgres" ]; then
        kubectl create secret generic ${DB_NAME}-secret \
            --namespace=${NAMESPACE} \
            --from-literal=POSTGRES_USER=${DB_USERNAME} \
            --from-literal=POSTGRES_PASSWORD=${DB_PASSWORD} \
            --from-literal=POSTGRES_DB=${DB_NAME} \
            --dry-run=client -o yaml | kubectl apply -f -
    elif [ "${DB_TYPE}" == "mongodb" ]; then
        kubectl create secret generic ${DB_NAME}-secret \
            --namespace=${NAMESPACE} \
            --from-literal=MONGO_INITDB_ROOT_USERNAME=${DB_USERNAME} \
            --from-literal=MONGO_INITDB_ROOT_PASSWORD=${DB_PASSWORD} \
            --from-literal=MONGO_INITDB_DATABASE=${DB_NAME} \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
}

# Create the StorageClass
create_storage_class() {
    if ! kubectl get storageclass local-storage &>/dev/null; then
        cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
    fi
}

# Create NetworkPolicy that allows external access
create_network_policy() {
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${DB_NAME}-network-policy
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${DB_NAME}
  ingress:
  - ports:
    - protocol: TCP
      port: ${DB_PORT}
  policyTypes:
  - Ingress
EOF
}

# Initialize host directory
initialize_host_directory() {
    echo "Creating storage directory..."
    sudo mkdir -p /data/${NAMESPACE}/${DB_NAME}
    sudo chown -R 999:999 /data/${NAMESPACE}/${DB_NAME}
    sudo chmod -R 700 /data/${NAMESPACE}/${DB_NAME}
}

# Create PV
create_persistent_volume() {
    # Get first available node
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${NAMESPACE}-${DB_NAME}-pv
  labels:
    type: database
    app: ${DB_NAME}
    namespace: ${NAMESPACE}
spec:
  capacity:
    storage: ${STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-storage
  hostPath:
    path: /data/${NAMESPACE}/${DB_NAME}
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - ${NODE_NAME}
EOF
}

# Create PVC
create_persistent_volume_claim() {
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${DB_NAME}-pvc
  namespace: ${NAMESPACE}
spec:
  storageClassName: local-storage
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${STORAGE_SIZE}
  selector:
    matchLabels:
      type: database
      app: ${DB_NAME}
      namespace: ${NAMESPACE}
EOF
}

# Create StatefulSet
create_statefulset() {
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ${DB_NAME}
  namespace: ${NAMESPACE}
spec:
  serviceName: ${DB_NAME}
  replicas: 1
  selector:
    matchLabels:
      app: ${DB_NAME}
      type: database
  template:
    metadata:
      labels:
        app: ${DB_NAME}
        type: database
    spec:
      securityContext:
        fsGroup: 999
        runAsUser: 999
        runAsGroup: 999
      containers:
      - name: ${DB_NAME}
        image: ${DB_IMAGE}
        imagePullPolicy: IfNotPresent
        securityContext:
          allowPrivilegeEscalation: false
          runAsUser: 999
          runAsGroup: 999
          capabilities:
            drop: ["ALL"]
        env:
        - name: ${ENV_USERNAME_VAR}
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: ${ENV_USERNAME_VAR}
        - name: ${ENV_PASSWORD_VAR}
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: ${ENV_PASSWORD_VAR}
        - name: ${ENV_DB_VAR}
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: ${ENV_DB_VAR}
        ports:
        - name: db-port
          containerPort: ${DB_PORT}
          protocol: TCP
        volumeMounts:
        - name: data
          mountPath: ${VOLUME_MOUNT_PATH}
        resources:
          requests:
            memory: "256Mi"
            cpu: "200m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          exec:
            command: ["/bin/sh", "-c", "${READINESS_CMD}"]
          initialDelaySeconds: 30
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: ${DB_PORT}
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${DB_NAME}-pvc
EOF
}

# Create Service
create_service() {
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${DB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${DB_NAME}
    type: database
spec:
  type: NodePort
  ports:
    - port: ${DB_PORT}
      targetPort: ${DB_PORT}
      protocol: TCP
      name: db-port
      nodePort: ${PORT}
  selector:
    app: ${DB_NAME}
    type: database
EOF
}

# Create Ingress
create_ingress() {
    if [ ! -z "${DOMAIN_NAME}" ]; then
        cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${DB_NAME}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: "letsencrypt-dns"
    nginx.ingress.kubernetes.io/backend-protocol: "TCP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
spec:
  rules:
  - host: ${DOMAIN_NAME}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${DB_NAME}
            port:
              number: ${DB_PORT}
  tls:
  - hosts:
    - ${DOMAIN_NAME}
    secretName: ${DB_NAME}-tls
EOF
    fi
}

# Test database connection
test_database_connection() {
    echo "🔍 Testing database connection..."
    
    # Wait for pod to be running
    echo "⏳ Waiting for database pod to be ready..."
    kubectl wait --for=condition=Ready pod -l app=${DB_NAME} -n ${NAMESPACE} --timeout=300s
    
    # Additional wait for database initialization
    echo "⏳ Waiting for database initialization..."
    sleep 30
    
    # Get service IP
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    echo "📌 Database is accessible at: ${NODE_IP}:${PORT}"
    
    # Test connection based on database type
    case ${DB_TYPE} in
        "mysql")
            echo "🔍 Testing MySQL connection..."
            kubectl run -n ${NAMESPACE} test-mysql --rm --image=mysql:${DB_VERSION} \
                -i --restart=Never --command -- mysql -h ${DB_NAME} \
                -u${DB_USERNAME} -p${DB_PASSWORD} -e "SELECT 1;" || true
            ;;
        "postgres")
            echo "🔍 Testing PostgreSQL connection..."
            kubectl run -n ${NAMESPACE} test-pg --rm --image=postgres:${DB_VERSION} \
                -i --restart=Never --command -- psql -h ${DB_NAME} \
                -U ${DB_USERNAME} -c "SELECT 1;" || true
            ;;
        "mongodb")
            echo "🔍 Testing MongoDB connection..."
            kubectl run -n ${NAMESPACE} test-mongo --rm --image=mongo:${DB_VERSION} \
                -i --restart=Never --command -- mongosh --host ${DB_NAME} \
                -u ${DB_USERNAME} -p ${DB_PASSWORD} --eval "db.runCommand({ping:1})" || true
            ;;
    esac
}

# Main deployment function
main() {
    echo "🚀 Starting database deployment..."
    
    # Create namespace and validate
    echo "🔑 Creating namespace..."
    create_namespace_resources
    validate_unique_deployment
    
    echo "⚙️ Configuring database..."
    configure_database
    
    echo "📂 Creating StorageClass..."
    create_storage_class
    
    echo "🔒 Creating NetworkPolicy..."
    create_network_policy
    
    echo "📂 Initializing storage..."
    initialize_host_directory
    
    echo "💾 Creating PV..."
    create_persistent_volume
    
    echo "📝 Creating PVC..."
    create_persistent_volume_claim
    
    # Wait for PVC to be bound
    echo "⏳ Waiting for PVC to bind..."
    kubectl wait --for=condition=Bound pvc/${DB_NAME}-pvc -n ${NAMESPACE} --timeout=300s
    
    echo "🚀 Creating StatefulSet..."
    create_statefulset
    
    echo "🔌 Creating Service..."
    create_service
    
    if [ ! -z "${DOMAIN_NAME}" ]; then
        echo "🌐 Creating Ingress..."
        create_ingress
    fi
    
    # Test database connection
    test_database_connection
    
    echo "✅ Database deployment completed successfully!"
    echo ""
    echo "📊 Database Details:"
    echo "  - Name: ${DB_NAME}"
    echo "  - Type: ${DB_TYPE}"
    echo "  - Version: ${DB_VERSION}"
    echo "  - Namespace: ${NAMESPACE}"
    echo "  - Port: ${DB_PORT}"
    echo ""
    echo "🔌 Connection Information:"
    echo "  - Internal: ${DB_NAME}.${NAMESPACE}.svc.cluster.local:${DB_PORT}"
    if [ ! -z "${DOMAIN_NAME}" ]; then
        echo "  - External: ${DB_NAME}-${NAMESPACE}.${DOMAIN_NAME}"
    fi
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    echo "  - NodePort: ${NODE_IP}:${PORT}"
    echo ""
    echo "🔑 Credentials:"
    echo "  - Username: ${DB_USERNAME}"
    if [ "${DB_TYPE}" == "mysql" ]; then
        echo "  - Root Password: ${DB_PASSWORD}"
    else
        echo "  - Password: ${DB_PASSWORD}"
    fi
    echo ""
    echo "🔍 Monitor database status:"
    echo "  kubectl get pods -n ${NAMESPACE} -l app=${DB_NAME}"
    echo "  kubectl logs -f -n ${NAMESPACE} -l app=${DB_NAME}"
    echo ""
    echo "🔍 Test database connection:"
    case ${DB_TYPE} in
        "mysql")
            echo "  mysql -h ${NODE_IP} -P ${PORT} -u${DB_USERNAME} -p${DB_PASSWORD} ${DB_NAME}"
            ;;
        "postgres")
            echo "  PGPASSWORD=${DB_PASSWORD} psql -h ${NODE_IP} -p ${PORT} -U ${DB_USERNAME} ${DB_NAME}"
            ;;
        "mongodb")
            echo "  mongosh \"mongodb://${DB_USERNAME}:${DB_PASSWORD}@${NODE_IP}:${PORT}/${DB_NAME}\""
            ;;
    esac
}

# Execute main function
main