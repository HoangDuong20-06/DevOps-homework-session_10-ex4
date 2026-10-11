#!/bin/bash
# ==============================================================================
# Bai 4: Custom Network & Named Volume bang Docker CLI
# Cum 2 container: Backend Web API (app-container) + PostgreSQL (db-server)
# - Custom Bridge Network: app-net (giao tiep noi bo qua ten service / DNS)
# - Named Volume: db-data -> /var/lib/postgresql/data (data persistence)
# Cach chay:
#   chmod +x commands.sh
#   ./commands.sh
#   (Windows: chay trong Git Bash; yeu cau Docker Desktop dang running)
# ==============================================================================

set -e

NETWORK="app-net"
VOLUME="db-data"
DB_CONTAINER="db-server"
APP_CONTAINER="app-container"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="postgres123"
POSTGRES_DB="appdb"
POSTGRES_IMAGE="postgres:15-alpine"
# Backend Web API demo: nginx:alpine
# Ly do chon nginx:alpine thay vi alpine sleep:
#  1. Dung vai tro "Backend Web API" (phuc vu HTTP, thay the duoc bang Spring Boot image tu build).
#  2. Nguon goc Alpine nen van co san `ping` -> pass bai kiem tra:
#       docker exec -it app-container ping -c 2 db-server
# Neu muon dung backend Spring Boot tu build, thay dong docker run app-container
# bang image backend cua ban (vi du: my-backend:1.0), giu nguyen --network va -e DB_*.
BACKEND_IMAGE="nginx:alpine"

echo "========== [0/7] Don dep container/network cu (neu co, de script chay lai idempotent) =========="
docker rm -f "$DB_CONTAINER" "$APP_CONTAINER" 2>/dev/null || true

echo "========== [1/7] Tao Custom Bridge Network: $NETWORK =========="
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "-> Network '$NETWORK' da ton tai, bo qua buoc tao."
else
  docker network create --driver bridge "$NETWORK"
fi
docker network ls | grep "$NETWORK" || true

echo "========== [2/7] Tao Named Volume: $VOLUME =========="
docker volume create "$VOLUME"
docker volume ls | grep "$VOLUME" || true

echo "========== [3/7] Khoi chay Database Container: $DB_CONTAINER ($POSTGRES_IMAGE) =========="
docker run -d \
  --name "$DB_CONTAINER" \
  --network "$NETWORK" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -v "$VOLUME":/var/lib/postgresql/data \
  "$POSTGRES_IMAGE"

echo "-> Cho PostgreSQL san sang (pg_isready, toi da ~60s)..."
for i in $(seq 1 30); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    echo "-> PostgreSQL da READY."
    break
  fi
  echo "   ... doi 2s ($i/30)"
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo "ERROR: PostgreSQL khong ready sau 60s. Log:"
    docker logs "$DB_CONTAINER" | tail -50
    exit 1
  fi
done

echo "========== [4/7] Khoi chay Backend Container: $APP_CONTAINER ($BACKEND_IMAGE) =========="
# Truyen bien ket noi DB bang hostname db-server (DNS noi bo cua app-net).
# Backend that se dung DB_HOST=db-server thay vi IP cung -> khong vo khi IP container doi.
docker run -d \
  --name "$APP_CONTAINER" \
  --network "$NETWORK" \
  -e DB_HOST="$DB_CONTAINER" \
  -e DB_PORT=5432 \
  -e DB_USER="$POSTGRES_USER" \
  -e DB_PASSWORD="$POSTGRES_PASSWORD" \
  -e DB_NAME="$POSTGRES_DB" \
  -e DATABASE_URL="postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$DB_CONTAINER:5432/$POSTGRES_DB" \
  -p 8080:80 \
  "$BACKEND_IMAGE"

echo "-> Kiem tra bien moi truong DB trong backend:"
docker exec "$APP_CONTAINER" env | grep -E "DB_|DATABASE_URL" || docker inspect "$APP_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "DB_|DATABASE_URL"
docker ps --filter "name=$DB_CONTAINER" --filter "name=$APP_CONTAINER"

echo "========== [5/7] Kiem tra DNS resolution: ping db-server tu backend =========="
docker network inspect "$NETWORK"
docker exec "$APP_CONTAINER" ping -c 2 "$DB_CONTAINER"
echo "-> Ping thanh cong: $APP_CONTAINER da giai ma '$DB_CONTAINER' thanh IP noi bo."

echo "========== [6/7] Test Data Persistence =========="
echo "--- [6.1] Tao bang + them du lieu mau vao DB ---"
docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "CREATE TABLE IF NOT EXISTS persistence_demo (id SERIAL PRIMARY KEY, message TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT now());"
docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "INSERT INTO persistence_demo (message) VALUES ('hello-persistence-$(date +%s)');"
echo "--- Du lieu TRUOC khi xoa container: ---"
docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT * FROM persistence_demo ORDER BY id;"

echo "--- [6.2] Xoa CUNG container DB (volume $VOLUME van giu lai) ---"
docker rm -f "$DB_CONTAINER"
echo "-> Kiem tra volume van ton tai sau khi rm -f:"
docker volume ls | grep "$VOLUME"
docker volume inspect "$VOLUME"

echo "--- [6.3] Khoi chay LAI container DB moi, gan CUNG volume $VOLUME ---"
docker run -d \
  --name "$DB_CONTAINER" \
  --network "$NETWORK" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -v "$VOLUME":/var/lib/postgresql/data \
  "$POSTGRES_IMAGE"

echo "-> Cho PostgreSQL (container moi) san sang..."
for i in $(seq 1 30); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    echo "-> PostgreSQL (moi) da READY."
    break
  fi
  echo "   ... doi 2s ($i/30)"
  sleep 2
  if [ "$i" -eq 30 ]; then
    echo "ERROR: PostgreSQL moi khong ready. Log:"
    docker logs "$DB_CONTAINER" | tail -50
    exit 1
  fi
done

echo "--- Du lieu SAU khi tai tao container (phai NGUYEN VEN): ---"
docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT * FROM persistence_demo ORDER BY id;"
ROW_COUNT=$(docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c "SELECT COUNT(*) FROM persistence_demo;")
echo "-> So dong trong bang persistence_demo: $ROW_COUNT"
echo "-> Neu COUNT >= 1 thi DATA PERSISTENCE DAT."

echo "========== [7/7] Kiem tra tong hop (danh cho cham bai) =========="
echo '$ docker network ls | grep app-net'
docker network ls | grep "$NETWORK" || true
echo '$ docker volume ls | grep db-data'
docker volume ls | grep "$VOLUME" || true
echo '$ docker ps (2 container phai Up)'
docker ps --filter "name=$DB_CONTAINER" --filter "name=$APP_CONTAINER"
echo '$ docker network inspect app-net (rut gon: Containers)'
docker network inspect "$NETWORK" --format '{{json .Containers}}'
echo '$ docker exec app-container ping -c 2 db-server (chay lai lan nua de minh hoa)'
docker exec "$APP_CONTAINER" ping -c 2 "$DB_CONTAINER"

echo ""
echo "==================== HOAN TAT ===================="
echo "Ping db-server tu backend: THANH CONG (DNS noi bo cua app-net)."
echo "Data persistence: NGUYEN VEN sau khi docker rm -f + tao lai container."
echo "De don dep (khong bat buoc khi nop bai):"
echo "  docker rm -f $APP_CONTAINER $DB_CONTAINER; docker network rm $NETWORK; docker volume rm $VOLUME"
