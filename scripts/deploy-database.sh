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
PORT=${9:-30000}           # Default port for NodePort

# Validate required parameters
if [ -z "$DB_NAME" ] || [ -z "$DB_TYPE" ] || [ -z "$DB_VERSION" ] || [ -z "$NAMESPACE" ]; then
    echo "❌ Error: Missing required parameters"
    echo "Usage: $0 DB_NAME DB_TYPE DB_VERSION NAMESPACE [DB_PASSWORD] [DB_USERNAME] [DOMAIN_NAME] [STORAGE_SIZE] [PORT]"
    exit 1
fi

# Set MySQL-specific defaults
if [ "${DB_TYPE}" == "mysql" ]; then
    DB_PASSWORD=${DB_PASSWORD:-rootpassword}
    DB_USERNAME=${DB_USERNAME:-defaultuser}
fi

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
            ;;
        "postgres")
            DB_IMAGE="postgres:${DB_VERSION}"
            ENV_USERNAME_VAR="POSTGRES_USER"
            ENV_PASSWORD_VAR="POSTGRES_PASSWORD"
            ENV_DB_VAR="POSTGRES_DB"
            DB_PORT=5432
            VOLUME_MOUNT_PATH="/var/lib/postgresql/data"
            ;;
        "mongodb")
            DB_IMAGE="mongo:${DB_VERSION}"
            ENV_USERNAME_VAR="MONGO_INITDB_ROOT_USERNAME"
            ENV_PASSWORD_VAR="MONGO_INITDB_ROOT_PASSWORD"
            ENV_DB_VAR="MONGO_INITDB_DATABASE"
            DB_PORT=27017
            VOLUME_MOUNT_PATH="/data/db"
            ;;
        *)
            echo "❌ Unsupported database type. Use postgres, mysql, or mongodb."
            exit 1
            ;;
    esac
}

# Create namespace and secret
create_namespace_resources() {
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    if [ "${DB_TYPE}" == "mysql" ]; then
        kubectl create secret generic ${DB_NAME}-secret \
            --from-literal=${ENV_ROOT_PASSWORD_VAR}=${DB_PASSWORD} \
            --from-literal=${ENV_USERNAME_VAR}=${DB_USERNAME} \
            --from-literal=${ENV_PASSWORD_VAR}=${DB_PASSWORD} \
            --from-literal=${ENV_DB_VAR}=${DB_NAME} \
            --namespace=${NAMESPACE} \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        kubectl create secret generic ${DB_NAME}-secret \
            --from-literal=${ENV_USERNAME_VAR}=${DB_USERNAME} \
            --from-literal=${ENV_PASSWORD_VAR}=${DB_PASSWORD} \
            --from-literal=${ENV_DB_VAR}=${DB_NAME} \
            --namespace=${NAMESPACE} \
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

# Initialize host directory
initialize_host_directory() {
    sudo mkdir -p /data/${NAMESPACE}/${DB_NAME}
    sudo chown -R 999:999 /data/${NAMESPACE}/${DB_NAME}
    sudo chmod -R 700 /data/${NAMESPACE}/${DB_NAME}
}

# Create PV
create_persistent_volume() {
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
    if [ "${DB_TYPE}" == "mysql" ]; then
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
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: MYSQL_ROOT_PASSWORD
        - name: MYSQL_USER
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: MYSQL_USER
        - name: MYSQL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: MYSQL_PASSWORD
        - name: MYSQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: ${DB_NAME}-secret
              key: MYSQL_DATABASE
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
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${DB_NAME}-pvc
EOF
    else
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
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ${DB_NAME}-pvc
EOF
    fi
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
    cert-manager.io/cluster-issuer: "letsencrypt-cloudflare"
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

# Function to create monitoring configurations
create_monitoring_config() {
    # Create ServiceMonitor
    cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ${DB_NAME}-monitor
  namespace: ${NAMESPACE}
  labels:
    release: prometheus
spec:
  endpoints:
  - interval: 30s
    port: metrics
    path: /metrics
  namespaceSelector:
    matchNames:
    - ${NAMESPACE}
  selector:
    matchLabels:
      app: ${DB_NAME}-${DB_TYPE}-exporter
---
# Storage Monitoring Rules and Alerts
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ${DB_NAME}-storage-rules
  namespace: ${NAMESPACE}
  labels:
    release: prometheus
spec:
  groups:
  - name: ${NAMESPACE}.storage.rules
    rules:
    # Storage Metrics
    - record: db_storage_used_bytes
      expr: |
        kubelet_volume_stats_used_bytes{persistentvolumeclaim="${DB_NAME}-pvc",namespace="${NAMESPACE}"}
    
    - record: db_storage_available_bytes
      expr: |
        kubelet_volume_stats_available_bytes{persistentvolumeclaim="${DB_NAME}-pvc",namespace="${NAMESPACE}"}
    
    - record: db_storage_total_bytes
      expr: |
        kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="${DB_NAME}-pvc",namespace="${NAMESPACE}"}
    
    - record: db_storage_used_percentage
      expr: |
        (kubelet_volume_stats_used_bytes{persistentvolumeclaim="${DB_NAME}-pvc",namespace="${NAMESPACE}"} / 
         kubelet_volume_stats_capacity_bytes{persistentvolumeclaim="${DB_NAME}-pvc",namespace="${NAMESPACE}"}) * 100

    # Storage Alerts
    - alert: StorageNearlyFull
      expr: |
        db_storage_used_percentage > 75
      for: 5m
      labels:
        severity: warning
        namespace: "${NAMESPACE}"
        database: "${DB_NAME}"
      annotations:
        summary: "Storage Nearly Full in ${NAMESPACE}"
        description: "Database storage is at {{ $value | printf \"%.2f\" }}% capacity"

    - alert: StorageCritical
      expr: |
        db_storage_used_percentage > 85
      for: 5m
      labels:
        severity: critical
        namespace: "${NAMESPACE}"
        database: "${DB_NAME}"
      annotations:
        summary: "Storage Critical in ${NAMESPACE}"
        description: "Database storage is at {{ $value | printf \"%.2f\" }}% capacity"

    - alert: StorageEmergency
      expr: |
        db_storage_used_percentage > 95
      for: 2m
      labels:
        severity: emergency
        namespace: "${NAMESPACE}"
        database: "${DB_NAME}"
      annotations:
        summary: "Storage Emergency in ${NAMESPACE}"
        description: "CRITICAL: Storage is at {{ $value | printf \"%.2f\" }}% capacity"

    - alert: StorageGrowthRate
      expr: |
        rate(db_storage_used_bytes[1h]) > 0
      for: 15m
      labels:
        severity: info
        namespace: "${NAMESPACE}"
        database: "${DB_NAME}"
      annotations:
        summary: "Storage Growth Detected in ${NAMESPACE}"
        description: "Storage growing at {{ $value | humanize }}B per second"
EOF

    # Create Grafana Dashboard
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${DB_NAME}-storage-dashboard
  namespace: ${NAMESPACE}
  labels:
    grafana_dashboard: "true"
data:
  storage-dashboard.json: |
    {
      "annotations": {
        "list": []
      },
      "editable": true,
      "graphTooltip": 0,
      "links": [],
      "panels": [
        {
          "datasource": "Prometheus",
          "fieldConfig": {
            "defaults": {
              "mappings": [],
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 75 },
                  { "color": "orange", "value": 85 },
                  { "color": "red", "value": 95 }
                ]
              },
              "unit": "percent"
            }
          },
          "gridPos": {
            "h": 8,
            "w": 12,
            "x": 0,
            "y": 0
          },
          "id": 1,
          "options": {
            "reduceOptions": {
              "calcs": ["lastNotNull"],
              "fields": "",
              "values": false
            },
            "showThresholdLabels": false,
            "showThresholdMarkers": true
          },
          "pluginVersion": "7.2.0",
          "targets": [
            {
              "expr": "db_storage_used_percentage{namespace=\"${NAMESPACE}\"}",
              "interval": "",
              "legendFormat": "",
              "refId": "A"
            }
          ],
          "title": "Storage Usage",
          "type": "gauge"
        },
        {
          "datasource": "Prometheus",
          "fieldConfig": {
            "defaults": {
              "custom": {},
              "unit": "bytes"
            }
          },
          "gridPos": {
            "h": 8,
            "w": 12,
            "x": 12,
            "y": 0
          },
          "id": 2,
          "options": {
            "colorMode": "value",
            "graphMode": "area",
            "justifyMode": "auto",
            "orientation": "auto",
            "reduceOptions": {
              "calcs": ["lastNotNull"],
              "fields": "",
              "values": false
            }
          },
          "pluginVersion": "7.2.0",
          "targets": [
            {
              "expr": "db_storage_available_bytes{namespace=\"${NAMESPACE}\"}",
              "interval": "",
              "legendFormat": "Available",
              "refId": "A"
            },
            {
              "expr": "db_storage_used_bytes{namespace=\"${NAMESPACE}\"}",
              "interval": "",
              "legendFormat": "Used",
              "refId": "B"
            }
          ],
          "title": "Storage Breakdown",
          "type": "stat"
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "Prometheus",
          "fieldConfig": {
            "defaults": {
              "custom": {},
              "unit": "bytes"
            }
          },
          "fill": 1,
          "gridPos": {
            "h": 8,
            "w": 24,
            "x": 0,
            "y": 8
          },
          "id": 3,
          "legend": {
            "avg": false,
            "current": false,
            "max": false,
            "min": false,
            "show": true,
            "total": false,
            "values": false
          },
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 2,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {
              "expr": "rate(db_storage_used_bytes{namespace=\"${NAMESPACE}\"}[1h])",
              "interval": "",
              "legendFormat": "Growth Rate",
              "refId": "A"
            }
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeRegions": [],
          "timeShift": null,
          "title": "Storage Growth Rate",
          "tooltip": {
            "shared": true,
            "sort": 0,
            "value_type": "individual"
          },
          "type": "graph",
          "xaxis": {
            "buckets": null,
            "mode": "time",
            "name": null,
            "show": true,
            "values": []
          },
          "yaxes": [
            {
              "format": "bytes",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": true
            },
            {
              "format": "short",
              "label": null,
              "logBase": 1,
              "max": null,
              "min": null,
              "show": true
            }
          ]
        }
      ],
      "refresh": "5s",
      "schemaVersion": 26,
      "style": "dark",
      "tags": [],
      "templating": {
        "list": []
      },
      "time": {
        "from": "now-6h",
        "to": "now"
      },
      "timepicker": {},
      "timezone": "",
      "title": "${DB_NAME} Storage Monitor - ${NAMESPACE}",
      "uid": "${NAMESPACE}-storage",
      "version": 1
    }
EOF
}

# Main deployment function
main() {
    echo "Starting database deployment..."

    echo "Configuring database..."
    configure_database
    echo "Database configuration completed."

    echo "Creating storage class..."
    create_storage_class
    echo "Storage class created."

    echo "Initializing host directory..."
    initialize_host_directory
    echo "Host directory initialized."

    echo "Creating namespace resources..."
    create_namespace_resources
    echo "Namespace resources created."

    echo "Creating persistent volume..."
    create_persistent_volume
    echo "Persistent volume created."

    echo "Creating persistent volume claim..."
    create_persistent_volume_claim
    echo "Persistent volume claim created."

    echo "Creating statefulset..."
    create_statefulset
    echo "Statefulset created."

    echo "Creating service..."
    create_service
    echo "Service created."

    echo "Creating ingress..."
    create_ingress
    echo "Ingress created."

    echo "Setting up monitoring..."
    create_monitoring_config
    echo "Monitoring setup completed."

    echo "✅ Database deployment completed!"
    echo "Access Info:"
    echo "- Internal: ${DB_NAME}.${NAMESPACE}.svc.cluster.local:${DB_PORT}"
    if [ ! -z "${DOMAIN_NAME}" ]; then
        echo "- External: ${DOMAIN_NAME}"
    fi
    echo "- NodePort: ${PORT}"
    echo ""
    echo "Storage Monitoring Info:"
    echo "- Storage Metrics available in Prometheus"
    echo "- View the Grafana dashboard: ${DB_NAME} Storage Monitor - ${NAMESPACE}"
    echo "- Alert thresholds:"
    echo "  * Warning: 75% usage"
    echo "  * Critical: 85% usage"
    echo "  * Emergency: 95% usage"
    echo ""
    echo "PromQL Queries for Storage:"
    echo "- Used Storage: db_storage_used_bytes{namespace=\"${NAMESPACE}\"}"
    echo "- Available Storage: db_storage_available_bytes{namespace=\"${NAMESPACE}\"}"
    echo "- Usage Percentage: db_storage_used_percentage{namespace=\"${NAMESPACE}\"}"
}

# Execute main function
main