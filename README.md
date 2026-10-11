# Bài 4: Custom Network & Named Volume bằng Docker CLI

## 1. Mục tiêu
- Tạo **Custom Bridge Network** `app-net` để các container giao tiếp nội bộ qua **tên container (DNS resolution)** thay vì IP cứng.
- Tạo **Named Volume** `db-data` để lưu trữ dữ liệu PostgreSQL bền vững, sống sót sau khi xóa/tái tạo container.
- Kết nối cụm 2 container: **Backend Web API (`app-container`) + PostgreSQL (`db-server`)** hoàn toàn bằng **Docker CLI thủ công** (không dùng Compose).

## 2. Kiến trúc

```
                    ┌─────────────────────────────┐
                    │   Custom Bridge: app-net     │
                    │   (embedded DNS 127.0.0.11)  │
                    │                              │
                    │  ┌────────────┐  ┌─────────┐ │
                    │  │ db-server  │◄─┤app-     │ │
                    │  │ postgres:  │  │container│ │
                    │  │ 15-alpine  │  │nginx:   │ │
                    │  │ :5432      │  │ alpine  │ │
                    │  └─────┬──────┘  └─────────┘ │
                    └────────┼────────────────────┘
                             │ mount
                      ┌──────▼──────┐
                      │ Named Volume │
                      │   db-data    │
                      │ /var/lib/    │
                      │ postgresql/  │
                      │ data         │
                      └─────────────┘
```

- Backend kết nối DB qua hostname `db-server` (biến `DB_HOST=db-server`, `DATABASE_URL=postgresql://postgres:***@db-server:5432/appdb`), không dùng IP.
- DB mount `db-data:/var/lib/postgresql/data` — đúng đường dẫn data mặc định của image `postgres`.

## 3. File nộp

| File | Mô tả |
|---|---|
| `commands.sh` | Script thực thi toàn bộ thao tác: tạo network/volume, chạy DB + Backend, test ping/DNS, test persistence (thêm → `rm -f` → chạy lại → verify). Idempotent, chạy lại nhiều lần được. |
| `README.md` | File này: giải thích + hướng dẫn chạy + kiểm tra. |

Đường dẫn nộp trên GitHub theo đề: `homework/session_10/ex4/`.

## 4. Cách chạy

Yêu cầu: Docker Desktop / Docker Engine đang chạy.

```bash
# Trong Git Bash / Linux / macOS:
chmod +x commands.sh
./commands.sh

# Hoặc chạy từng lệnh thủ công:
bash commands.sh
```

> Windows PowerShell/CMD: chạy trong **Git Bash** để `grep`, `$(...)`, `for` hoạt động.

Script tự làm các bước:

1. Dọn container cũ `db-server`, `app-container` (để chạy lại không lỗi `Conflict: name already in use`).
2. `docker network create --driver bridge app-net` (bỏ qua nếu đã tồn tại).
3. `docker volume create db-data`.
4. `docker run -d --name db-server --network app-net -e POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB -v db-data:/var/lib/postgresql/data postgres:15-alpine`, chờ `pg_isready`.
5. `docker run -d --name app-container --network app-net -e DB_HOST=db-server -e DB_PORT=5432 -e DB_USER/DB_PASSWORD/DB_NAME -e DATABASE_URL -p 8080:80 nginx:alpine`.
6. `docker exec app-container ping -c 2 db-server` → kiểm tra DNS nội bộ.
7. Test persistence:
   - `psql ... CREATE TABLE persistence_demo ...; INSERT ...; SELECT ...`
   - `docker rm -f db-server` (xóa cứng, **không** xóa volume)
   - `docker run -d --name db-server ... -v db-data:/var/lib/postgresql/data ...` (tạo lại, gắn cùng volume)
   - `SELECT ...` lại → dữ liệu nguyên vẹn, `COUNT(*) >= 1`.

### Nếu dùng backend Spring Boot tự build

Thay image `nginx:alpine` bằng image của bạn, giữ nguyên `--network` và `-e DB_*`:

```bash
docker build -t my-backend:1.0 .
docker run -d --name app-container --network app-net \
  -e DB_HOST=db-server -e DB_PORT=5432 \
  -e DB_USER=postgres -e DB_PASSWORD=postgres123 -e DB_NAME=appdb \
  -p 8080:8080 my-backend:1.0
```

## 5. Lệnh kiểm tra (theo đề)

```bash
docker network ls | grep app-net
docker volume ls | grep db-data
docker network inspect app-net
docker exec -it app-container ping -c 2 db-server
```

Thêm lệnh hữu ích:

```bash
# Xem container nào đang gắn vào network
docker network inspect app-net --format '{{json .Containers}}'

# Xem biến DB trong backend
docker exec app-container env | grep DB_

# Xem data volume
docker volume inspect db-data

# Xem log DB
docker logs db-server | tail -50

# Verify persistence thủ công
docker exec db-server psql -U postgres -d appdb -c "SELECT * FROM persistence_demo;"
```

## 6. Kết quả mong đợi

- `docker network ls | grep app-net` → thấy `app-net` loại `bridge`, scope `local`.
- `docker volume ls | grep db-data` → thấy `db-data` driver `local` — tồn tại cả sau `docker rm -f db-server`.
- `docker network inspect app-net` → mục `Containers` chứa cả `db-server` và `app-container` với `IPv4Address` dạng `172.x.x.x/16`.
- `ping -c 2 db-server` từ `app-container`:
  - Phân giải `db-server` thành IP nội bộ (ví dụ `172.18.0.2`), `0% packet loss`, không báo `bad address`.
  - Chứng minh embedded DNS của custom bridge hoạt động (mạng `bridge` mặc định không làm được điều này ổn định).
- Persistence: `SELECT * FROM persistence_demo;` **trước và sau** `docker rm -f db-server` trả về cùng dữ liệu (`COUNT >= 1`).

Ví dụ output ping đạt:

```
PING db-server (172.18.0.2): 56 data bytes
64 bytes from 172.18.0.2: seq=0 ttl=64 time=0.2xx ms
64 bytes from 172.18.0.2: seq=1 ttl=64 time=0.1xx ms
--- db-server ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
```

## 7. Giải thích nhanh (để trả lời vấn đáp)

- **Vì sao cần custom network?** Mạng `bridge` mặc định không hỗ trợ DNS theo tên container (phải dùng `--link` legacy hoặc IP cứng dễ đổi). Custom bridge có embedded DNS `127.0.0.11`, container resolve nhau qua tên.
- **Vì sao mount `/var/lib/postgresql/data`?** Đó là `PGDATA` mặc định của image `postgres`; mount named volume vào đó thì file DB nằm ngoài layer container → xóa container không mất data.
- **Named volume vs bind mount?** Named volume do Docker quản lý (`/var/lib/docker/volumes/...`), portable, dễ backup (`docker volume ...`), không phụ thuộc path host như bind mount.
- **Vì sao truyền `DB_HOST=db-server`?** Để backend không hard-code IP; khi container DB tái tạo đổi IP, DNS `db-server` vẫn trỏ đúng.

## 8. Dọn dẹp (không bắt buộc khi nộp)

```bash
docker rm -f app-container db-server
docker network rm app-net
docker volume rm db-data
# Hoặc xóa luôn data test:
# docker volume rm db-data
```

## 9. Troubleshooting

| Lỗi | Nguyên nhân / Cách fix |
|---|---|
| `Conflict: name ... already in use` | Container cũ chưa xóa → script đã tự `docker rm -f` ở bước 0; nếu chạy tay thì chạy `docker rm -f db-server app-container` trước. |
| `bad address 'db-server'` khi ping | 2 container khác network → kiểm tra `docker network inspect app-net` phải chứa cả 2; chạy lại với `--network app-net`. |
| `ping: not found` | Backend image không có ping (ví dụ scratch/distroless) → dùng `nginx:alpine` / `alpine` như script mẫu. |
| `password authentication failed` / `POSTGRES_PASSWORD required` | Thiếu `-e POSTGRES_PASSWORD` → phải truyền đúng 3 biến `POSTGRES_USER/PASSWORD/DB`. |
| `pg_isready` lâu ready | Lần đầu image pull + init DB hơi lâu → chờ thêm; xem `docker logs db-server`. |
| `Cannot connect to Docker daemon` (Windows) | Docker Desktop chưa chạy → mở Docker Desktop rồi chạy lại script trong Git Bash. |
