#!/bin/bash

# Input variables
DB_NAME=$1
DB_TYPE=$2
DB_VERSION=$3
NAMESPACE=${4:-default}  # This will be the username in your case
DB_PASSWORD=$5
DB_USERNAME=${6:-defaultUser}
DOMAIN_NAME=$7
STORAGE_SIZE=${8:-1Gi}

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
        "postgres")
            DB_IMAGE="postgres:${DB_VERSION}"
            ENV_USERNAME_VAR="POSTGRES_USER"
            ENV_PASSWORD_VAR="POSTGRES_PASSWORD"
            ENV_DB_VAR="POSTGRES_DB"
            DB_PORT=5432
            VOLUME_MOUNT_PATH="/var/lib/postgresql/data"
            HEALTHCHECK_CMD='["CMD-SHELL", "pg_isready -U $POSTGRES_USER"]'
            ;;
        "mysql")
            DB_IMAGE="mysql:${DB_VERSION}"
            ENV_USERNAME_VAR="MYSQL_USER"
            ENV_PASSWORD_VAR="MYSQL_ROOT_PASSWORD"
            ENV_DB_VAR="MYSQL_DATABASE"
            DB_PORT=3306
            VOLUME_MOUNT_PATH="/var/lib/mysql"
            HEALTHCHECK_CMD='["CMD", "mysqladmin", "ping", "-h", "localhost"]'
            ;;
        "mongodb")
            DB_IMAGE="mongo:${DB_VERSION}"
            ENV_USERNAME_VAR="MONGO_INITDB_ROOT_USERNAME"
            ENV_PASSWORD_VAR="MONGO_INITDB_ROOT_PASSWORD"
            ENV_DB_VAR="MONGO_INITDB_DATABASE"
            DB_PORT=27017
            VOLUME_MOUNT_PATH="/data/db"
            HEALTHCHECK_CMD='["CMD", "mongosh", "--eval", "db.adminCommand(\"ping\")"]'
            ;;
        *)
            echo "❌ Unsupported database type. Use postgres, mysql, or mongodb."
            exit 1
            ;;
    esac
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

# Create NetworkPolicy
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
      type: database
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ${NAMESPACE}
    ports:
    - protocol: TCP
      port: ${DB_PORT}
  policyTypes:
  - Ingress
EOF
}

# Create namespace and secret
create_namespace_resources() {
    # Create namespace if not exists
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    # Label namespace for network policies
    kubectl label namespace ${NAMESPACE} name=${NAMESPACE} --overwrite

    # Create secret for database credentials
    kubectl create secret generic ${DB_NAME}-secret \
        --from-literal=${ENV_USERNAME_VAR}=${DB_USERNAME} \
        --from-literal=${ENV_PASSWORD_VAR}=${DB_PASSWORD} \
        --from-literal=${ENV_DB_VAR}=${DB_NAME} \
        --namespace=${NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -
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
        startupProbe:
          exec:
            command: ${HEALTHCHECK_CMD}
          failureThreshold: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ${HEALTHCHECK_CMD}
          initialDelaySeconds: 20
          periodSeconds: 10
        livenessProbe:
          exec:
            command: ${HEALTHCHECK_CMD}
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
  type: ClusterIP
  ports:
    - port: ${DB_PORT}
      targetPort: ${DB_PORT}
      protocol: TCP
      name: db-port
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
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "${DB_TYPE}"
spec:
  rules:
  - host: ${DB_NAME}-${NAMESPACE}.${DOMAIN_NAME}
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
    - ${DB_NAME}-${NAMESPACE}.${DOMAIN_NAME}
    secretName: ${DB_NAME}-tls
EOF
    fi
}

# Main deployment function
main() {
    echo "🚀 Starting database deployment..."
    
    # Validate deployment
    validate_unique_deployment
    
    # Get node name for PV node affinity
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    
    echo "⚙️ Configuring database..."
    configure_database
    
    echo "📂 Creating StorageClass..."
    create_storage_class
    
    echo "🔒 Creating NetworkPolicy..."
    create_network_policy
    
    echo "📂 Initializing storage..."
    initialize_host_directory
    
    echo "🔑 Creating namespace and secrets..."
    create_namespace_resources
    
    echo "💾 Creating PV..."
    create_persistent_volume
    
    echo "📝 Creating PVC..."
    create_persistent_volume_claim
    
    echo "⏳ Waiting for PVC to bind..."
    kubectl wait --for=condition=Bound pvc/${DB_NAME}-pvc -n ${NAMESPACE} --timeout=60s
    
    echo "🚀 Creating StatefulSet..."
    create_statefulset
    
    echo "🔌 Creating Service..."
    create_service
    
    if [ ! -z "${DOMAIN_NAME}" ]; then
        echo "🌐 Creating Ingress..."
        create_ingress
    fi
    
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
    echo ""
    echo "⏳ Wait for the database to be ready:"
    echo "  kubectl get pods -n ${NAMESPACE} -l app=${DB_NAME} -w"
    echo "  kubectl logs -f -n ${NAMESPACE} -l app=${DB_NAME}"
}

# Execute main function
main