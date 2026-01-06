#!/bin/bash
# =============================================================================
# Last9 Database Detection Script
# =============================================================================
# Scans the Kubernetes cluster for common databases and suggests appropriate
# metrics exporters for enhanced observability.
#
# Usage: ./detect-databases.sh [namespace]
#        ./detect-databases.sh --all-namespaces
#
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Database detection patterns
declare -A DB_PATTERNS=(
    ["postgresql"]="postgres|postgresql|pgbouncer|patroni|stolon|crunchy"
    ["mysql"]="mysql|mariadb|percona|vitess"
    ["mongodb"]="mongo|mongodb"
    ["redis"]="redis|keydb|dragonfly"
    ["elasticsearch"]="elasticsearch|elastic|opensearch"
    ["kafka"]="kafka|strimzi|confluent"
    ["cassandra"]="cassandra|scylla"
    ["memcached"]="memcached"
    ["rabbitmq"]="rabbitmq|rabbit"
    ["mssql"]="mssql|sqlserver"
    ["clickhouse"]="clickhouse"
    ["cockroachdb"]="cockroach|cockroachdb"
    ["etcd"]="etcd"
    ["consul"]="consul"
    ["vault"]="vault"
)

# Exporter recommendations
declare -A EXPORTERS=(
    ["postgresql"]="prometheus-community/prometheus-postgres-exporter"
    ["mysql"]="prometheus-community/prometheus-mysql-exporter"
    ["mongodb"]="prometheus-community/prometheus-mongodb-exporter"
    ["redis"]="prometheus-community/prometheus-redis-exporter"
    ["elasticsearch"]="prometheus-community/prometheus-elasticsearch-exporter"
    ["kafka"]="prometheus-community/prometheus-kafka-exporter"
    ["cassandra"]="instaclustr/cassandra-exporter (or builtin JMX)"
    ["memcached"]="prometheus-community/prometheus-memcached-exporter"
    ["rabbitmq"]="Built-in (enable prometheus plugin)"
    ["mssql"]="awaragi/prometheus-mssql-exporter"
    ["clickhouse"]="Built-in (/metrics endpoint)"
    ["cockroachdb"]="Built-in (/metrics endpoint)"
    ["etcd"]="Built-in (/metrics endpoint)"
    ["consul"]="Built-in (/metrics endpoint)"
    ["vault"]="Built-in (/metrics endpoint)"
)

# Installation commands
declare -A INSTALL_CMDS=(
    ["postgresql"]="helm install postgres-exporter prometheus-community/prometheus-postgres-exporter --set config.datasource.host=<POSTGRES_HOST>"
    ["mysql"]="helm install mysql-exporter prometheus-community/prometheus-mysql-exporter --set mysql.host=<MYSQL_HOST>"
    ["mongodb"]="helm install mongodb-exporter prometheus-community/prometheus-mongodb-exporter --set mongodb.uri=mongodb://<MONGO_HOST>:27017"
    ["redis"]="helm install redis-exporter prometheus-community/prometheus-redis-exporter --set redisAddress=redis://<REDIS_HOST>:6379"
    ["elasticsearch"]="helm install es-exporter prometheus-community/prometheus-elasticsearch-exporter --set es.uri=http://<ES_HOST>:9200"
    ["kafka"]="helm install kafka-exporter prometheus-community/prometheus-kafka-exporter --set kafkaServer=<KAFKA_HOST>:9092"
)

# Annotation templates
declare -A ANNOTATIONS=(
    ["postgresql"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9187"'
    ["mysql"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9104"'
    ["mongodb"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9216"'
    ["redis"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9121"'
    ["elasticsearch"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9114"'
    ["kafka"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9308"'
    ["rabbitmq"]='prometheus.io/scrape: "true"\nprometheus.io/port: "15692"'
    ["clickhouse"]='prometheus.io/scrape: "true"\nprometheus.io/port: "9363"'
    ["cockroachdb"]='prometheus.io/scrape: "true"\nprometheus.io/port: "8080"\nprometheus.io/path: "/_status/vars"'
)

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Last9 Database Detection${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_section() {
    echo -e "\n${YELLOW}▸ $1${NC}"
    echo -e "${YELLOW}$(printf '─%.0s' {1..60})${NC}"
}

detect_databases() {
    local namespace_flag="$1"
    local detected=()

    print_header
    echo -e "Scanning cluster for databases...\n"

    # Get all pods/deployments/statefulsets
    local resources
    resources=$(kubectl get pods,deployments,statefulsets $namespace_flag -o json 2>/dev/null || echo '{"items":[]}')

    for db in "${!DB_PATTERNS[@]}"; do
        local pattern="${DB_PATTERNS[$db]}"
        local matches

        # Search in resource names and images
        matches=$(echo "$resources" | jq -r --arg pattern "$pattern" '
            .items[] |
            select(
                (.metadata.name | test($pattern; "i")) or
                (.spec.containers[]?.image | test($pattern; "i")) or
                (.spec.template.spec.containers[]?.image | test($pattern; "i"))
            ) |
            "\(.metadata.namespace)/\(.metadata.name)"
        ' 2>/dev/null | sort -u)

        if [[ -n "$matches" ]]; then
            detected+=("$db")
            print_section "Detected: ${db^^}"

            echo -e "${GREEN}Found instances:${NC}"
            echo "$matches" | while read -r instance; do
                echo "  • $instance"
            done

            echo -e "\n${BLUE}Recommended exporter:${NC}"
            echo "  ${EXPORTERS[$db]:-No specific exporter recommended}"

            if [[ -n "${INSTALL_CMDS[$db]:-}" ]]; then
                echo -e "\n${BLUE}Installation:${NC}"
                echo "  ${INSTALL_CMDS[$db]}"
            fi

            if [[ -n "${ANNOTATIONS[$db]:-}" ]]; then
                echo -e "\n${BLUE}Pod annotations for auto-scraping:${NC}"
                echo -e "  ${ANNOTATIONS[$db]}"
            fi
        fi
    done

    if [[ ${#detected[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No databases detected in the cluster.${NC}"
        echo "This script detects: PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch,"
        echo "Kafka, Cassandra, Memcached, RabbitMQ, MSSQL, ClickHouse, CockroachDB,"
        echo "etcd, Consul, and Vault."
    else
        print_summary "${detected[@]}"
    fi
}

print_summary() {
    local detected=("$@")

    print_section "Summary"

    echo -e "${GREEN}Detected databases: ${#detected[@]}${NC}"
    for db in "${detected[@]}"; do
        echo "  • ${db}"
    done

    echo -e "\n${BLUE}Next steps:${NC}"
    echo "1. Install recommended exporters for each database"
    echo "2. Add prometheus.io annotations to your database pods"
    echo "3. The Last9 collector will auto-discover and scrape metrics"
    echo ""
    echo "For trace correlation, ensure your application uses OTel instrumentation"
    echo "which automatically traces database calls (JDBC, pg, mysql, mongodb, redis)."
}

generate_exporter_values() {
    local db="$1"
    local output_file="$2"

    case "$db" in
        postgresql)
            cat > "$output_file" << 'EOF'
# PostgreSQL Exporter Values
# helm install postgres-exporter prometheus-community/prometheus-postgres-exporter -f postgres-exporter-values.yaml

config:
  datasource:
    host: postgres.default.svc.cluster.local
    port: 5432
    user: postgres
    password: ""
    database: postgres
    sslmode: disable

serviceMonitor:
  enabled: false  # We use annotation-based discovery

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9187"
EOF
            ;;
        mysql)
            cat > "$output_file" << 'EOF'
# MySQL Exporter Values
# helm install mysql-exporter prometheus-community/prometheus-mysql-exporter -f mysql-exporter-values.yaml

mysql:
  host: mysql.default.svc.cluster.local
  port: 3306
  user: exporter
  pass: ""

serviceMonitor:
  enabled: false

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9104"
EOF
            ;;
        redis)
            cat > "$output_file" << 'EOF'
# Redis Exporter Values
# helm install redis-exporter prometheus-community/prometheus-redis-exporter -f redis-exporter-values.yaml

redisAddress: redis://redis.default.svc.cluster.local:6379

serviceMonitor:
  enabled: false

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9121"
EOF
            ;;
        mongodb)
            cat > "$output_file" << 'EOF'
# MongoDB Exporter Values
# helm install mongodb-exporter prometheus-community/prometheus-mongodb-exporter -f mongodb-exporter-values.yaml

mongodb:
  uri: "mongodb://mongodb.default.svc.cluster.local:27017"

serviceMonitor:
  enabled: false

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9216"
EOF
            ;;
        *)
            echo "No template available for $db"
            return 1
            ;;
    esac

    echo -e "${GREEN}Generated: $output_file${NC}"
}

# Main
main() {
    local namespace_flag="-A"
    local generate_values=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all-namespaces|-A)
                namespace_flag="-A"
                shift
                ;;
            -n|--namespace)
                namespace_flag="-n $2"
                shift 2
                ;;
            --generate)
                generate_values="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  -A, --all-namespaces    Scan all namespaces (default)"
                echo "  -n, --namespace NS      Scan specific namespace"
                echo "  --generate DB           Generate exporter values file for DB"
                echo "  -h, --help              Show this help"
                echo ""
                echo "Examples:"
                echo "  $0                      # Scan all namespaces"
                echo "  $0 -n production        # Scan production namespace"
                echo "  $0 --generate postgres  # Generate postgres exporter values"
                exit 0
                ;;
            *)
                namespace_flag="-n $1"
                shift
                ;;
        esac
    done

    if [[ -n "$generate_values" ]]; then
        generate_exporter_values "$generate_values" "${generate_values}-exporter-values.yaml"
        exit 0
    fi

    # Check kubectl access
    if ! kubectl cluster-info &>/dev/null; then
        echo -e "${RED}Error: Cannot connect to Kubernetes cluster${NC}"
        echo "Please ensure kubectl is configured correctly."
        exit 1
    fi

    detect_databases "$namespace_flag"
}

main "$@"
