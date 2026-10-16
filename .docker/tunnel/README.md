# Tunnel độc lập cho Hoa Theo Mùa và TaskCoper

Bộ này được lưu trong repo gateway để quản lý phiên bản, nhưng được copy lên server
và vận hành tại `/opt/hoatheomua-infra/tunnel`, ngoài thư mục checkout của runner.
Workflow app không gọi Compose này. Mỗi instance có project `ingress-<instance>`,
container mới `ingress-<instance>-cloudflared`, token riêng và network external.

## Kết quả rà soát source

| Source | Tunnel cũ | Network |
| --- | --- | --- |
| hoatheomua-be | `hoatheomua-cloudflare-dev` | `hoatheomua-network-dev` |
| hoatheomua-gateway | `hoatheomua-gateway-cloudflare-dev` | `hoatheomua-network-dev`, `hoatheomua-gateway-network-dev` |
| hoatheomua-gateway | `hoatheomua-gateway-cloudflare-prod` | `hoatheomua-network-prod`, `hoatheomua-gateway-network-prod` |
| taskcoper-be | `taskcoper-cloudflare-dev` | `taskcoper-network-dev` |
| taskcoper-be | `taskcoper-cloudflare-prod` | `taskcoper-network-prod` |
| taskcoper-be | `taskcoper-cloudflare-htm-dev` | `hoatheomua-network-dev` |
| hoatheomua-fe / taskcoper-fe | Không có tunnel | Dùng network chung tương ứng môi trường |

Các workflow triển khai dùng `.docker/compose.yaml`. Tunnel cũ thuộc cùng profile
với app; backend/gateway còn pull image cloudflared không ghim phiên bản. Các file
`docker-compose.yml` và overlay phục vụ chạy local không khai báo tunnel.
Source không có connector riêng cho `hoatheomua-be prod` hay `taskcoper htm-prod`;
không tạo thêm tunnel Cloudflare cho các môi trường này bằng suy đoán.

App Compose đã bỏ 6 service tunnel và chuyển network chung sang `external: true`.
Workflow backend/gateway kiểm tra network trước khi deploy, bỏ token tunnel và chỉ
prune image dangling quá 24 giờ. Script sync secrets cũng bỏ qua token tunnel cũ.
TaskCoper FE bỏ `driver`/`ipam` khỏi network external để Compose hợp lệ.

## Chọn instance đúng server và token

| Instance của manage.sh | Container cũ để đối chiếu | Token `CLOUDFLARE_TUNNEL_TOKEN` từ repo / GitHub Environment |
| --- | --- | --- |
| `hoatheomua-be-dev` | `hoatheomua-cloudflare-dev` | hoatheomua-be / dev |
| `hoatheomua-gateway-dev` | `hoatheomua-gateway-cloudflare-dev` | hoatheomua-gateway / dev |
| `hoatheomua-gateway-prod` | `hoatheomua-gateway-cloudflare-prod` | hoatheomua-gateway / prod |
| `taskcoper-dev` | `taskcoper-cloudflare-dev` | taskcoper-be / dev |
| `taskcoper-prod` | `taskcoper-cloudflare-prod` | taskcoper-be / prod |
| `taskcoper-htm-dev` | `taskcoper-cloudflare-htm-dev` | taskcoper-be / htm-dev |

Đây là inventory từ source, cần đối chiếu container đang chạy trên từng server.
Chỉ chuyển những instance thực sự đang dùng ở server đó. Giữ nguyên tunnel UUID,
DNS và Public Hostnames. Token khác repo/environment có thể thuộc tunnel khác nhau;
không gộp hoặc thay token cho nhau. GitHub không cho đọc lại giá trị secret qua CLI;
dùng bản secret đã lưu hoặc token của tunnel hiện hữu trong Cloudflare Dashboard.

## Chuyển đổi từng instance

1. Tạm ngưng chạy deployment trong lúc chuyển đổi. Ghi lại container cũ, tunnel UUID,
   Public Hostnames, origin, network và image đang chạy. Các lệnh inspect dưới đây
   chỉ lấy thông tin cần thiết, tránh dump toàn bộ container vì có token trong env.

   ```bash
   docker inspect --format '{{json .NetworkSettings.Networks}}' hoatheomua-gateway-cloudflare-prod
   docker inspect --format '{{.Image}}' hoatheomua-gateway-cloudflare-prod
   docker exec hoatheomua-gateway-cloudflare-prod cloudflared --version
   ```

   Lấy image ID từ lệnh trên rồi chạy `docker image inspect --format '{{json .RepoDigests}}' IMAGE_ID`.
   Dùng digest `cloudflare/cloudflared@sha256:...` đang chạy cho lần chuyển đầu tiên.
   Nếu image không có RepoDigest, chọn exact release tag đã kiểm tra, không dùng `latest`.

2. Copy **toàn bộ thư mục này**, gồm `env/instance.env.example`, lên
   `/opt/hoatheomua-infra/tunnel` trên đúng server. Bảo vệ thư mục bằng quyền 700.
   Ví dụ bên dưới dành cho gateway prod; thay instance theo bảng khi chuyển tunnel khác.

   ```bash
   cd /opt/hoatheomua-infra/tunnel
   chmod 700 . env
   cp -n env/instance.env.example env/hoatheomua-gateway-prod.env
   chmod 600 env/hoatheomua-gateway-prod.env
   ```

   Điền `CLOUDFLARED_IMAGE` và token hiện hữu vào file bằng editor trên server.
   Script loại bỏ token/image được export sẵn trong shell để luôn lấy hai giá trị
   từ đúng env file của instance được chọn. File `env/*.env` được gitignore.

3. Kiểm tra mọi origin của tunnel có thể truy cập qua các network trong bảng.
   Script giữ đúng network được khai báo trong source cũ. Nếu server đã được thêm
   network thủ công, bổ sung tương ứng vào bộ Compose mới trước khi chạy connector.
   Origin dùng tên service ổn định, ví dụ `http://hoatheomua-gateway-prod:8080`,
   `http://hoatheomua-fe-prod:3000`, `http://htm-taskcoper-api-prod:8080`,
   `http://htm-taskcoper-client-prod:80`; xác nhận port/config thực tế trên Dashboard.
   Không dùng IP container. Kiểm tra từ network tương ứng bằng công cụ HTTP hiện có
   trên server trước khi cho connector mới nhận traffic.

4. Bootstrap network, validate rồi chạy connector mới trong khi connector cũ còn chạy:

   ```bash
   bash manage.sh hoatheomua-gateway-prod bootstrap
   bash manage.sh hoatheomua-gateway-prod config
   bash manage.sh hoatheomua-gateway-prod up
   bash manage.sh hoatheomua-gateway-prod ps
   bash manage.sh hoatheomua-gateway-prod logs
   ```

   `bootstrap` chỉ tạo network còn thiếu, không xoá hay tạo lại network đang dùng.
   Network cũ có thể giữ label Compose cũ; app mới dùng `external: true` sẽ tái sử dụng
   network đó. Không chạy `down` từ bản Compose cũ khi chuyển đổi.
   `config` chỉ validate, không in token. `up` chờ healthcheck tối đa 120 giây;
   nếu thất bại thì giữ connector cũ, xem log và sửa connector mới trước khi tiếp tục.

5. Xác nhận connector mới hiện Healthy trên đúng tunnel trong Cloudflare Dashboard,
   log có kết nối được đăng ký, và kiểm tra **tất cả hostname** liên quan: FE,
   gateway, API trực tiếp, TaskCoper và các origin khác nếu có.
   Healthcheck chỉ xác nhận kết nối tới Cloudflare, chưa chứng minh origin hoạt động.
   Khi hai connector cùng chạy, request công khai có thể đi qua connector cũ;
   kiểm tra origin từ network mới ở bước 3 vẫn bắt buộc.

6. Sau khi xác minh, dừng đúng container cũ của instance đang chuyển, rồi kiểm tra
   lại toàn bộ hostname để xác nhận traffic thực sự đi qua connector mới:

   ```bash
   docker stop --time 60 hoatheomua-gateway-cloudflare-prod
   ```

   Nếu có lỗi: chạy `docker start hoatheomua-gateway-cloudflare-prod` ngay,
   sau đó `bash manage.sh hoatheomua-gateway-prod stop` và kiểm tra lại cấu hình.
   Dừng connector có thể ngắt kết nối dài đang bám connector đó; chuyển lúc ít traffic.
   Giữ container cũ đã dừng trong thời gian theo dõi để có thể rollback bằng `docker start`.

7. Triển khai thay đổi Compose/workflow app sau khi tunnel độc lập đã ổn định.
   Với từng môi trường, đảm bảo các network cần dùng đã tồn tại. Backend/gateway
   mới sẽ fail sớm nếu thiếu network. Không bật `COMPOSE_REMOVE_ORPHANS` hoặc thêm
   `--remove-orphans` trong giai đoạn chuyển đổi vì container cũ cần giữ để rollback.
   Sau một lần deploy app, kiểm tra container tunnel mới không đổi ID/StartedAt và
   hostname vẫn truy cập được. Có thể so sánh trước/sau bằng:

   ```bash
   docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.RestartCount}}' ingress-hoatheomua-gateway-prod-cloudflared
   ```

8. Khi đã hết nhu cầu rollback, xoá đúng container cũ đã dừng bằng `docker rm TEN_CONTAINER_CU`.
   Sau khi toàn bộ môi trường của repo đã chuyển và không còn rollback workflow cũ,
   có thể xoá secret tunnel cũ trong GitHub; CI/CD mới không đọc secret đó.

## Bootstrap server mới

Chạy `bootstrap` cho instance cần dùng trước khi deploy app. Ví dụ gateway prod
tạo cả `hoatheomua-network-prod` và `hoatheomua-gateway-network-prod`; TaskCoper
standalone cần `taskcoper-dev` hoặc `taskcoper-prod` trên server tương ứng.
Bootstrap không cần token và không khởi chạy tunnel. Deploy các origin trước khi
khởi chạy tunnel nếu đây là server mới. Các Compose local dùng tên network không
có hậu tố môi trường vẫn giữ cách vận hành cũ.

## Vận hành

- Cập nhật tunnel riêng: đổi digest/tag đã kiểm tra trong env của đúng instance,
  chạy `pull`, sau đó `up` trong cửa sổ bảo trì. Cập nhật một connector duy nhất vẫn
  có thể gây gián đoạn ngắn. App CI/CD không cập nhật image tunnel.
- `CLOUDFLARED_PROTOCOL` mặc định `auto`. Khi log chứng minh QUIC/UDP chập chờn,
  có thể thử `http2` trên dev, xác nhận TCP 7844 kết nối được và kiểm tra hostname
  trước khi áp dụng cho prod. Đây là thay đổi transport riêng với việc tách Compose.
- Log có rotation 10 MB × 5 file. Metrics/ready chỉ bind loopback bên trong container,
  không publish port trên host. Dùng `ps`, `logs` và Dashboard để theo dõi.
- `restart: unless-stopped` tự phục hồi khi process thoát hoặc Docker khởi động lại;
  trạng thái `unhealthy` tự nó không khiến Docker restart container. Nếu 1033 tiếp tục
  ngoài lúc deploy, đối chiếu log mất kết nối, RestartCount/OOM và mạng server.
- Không dùng `docker system prune`, `container prune`, `network prune` trong deploy app.
  Không đặt bộ tunnel hay env secrets trong workspace runner bị checkout dọn lại.
- Rollback app có thể giữ tunnel độc lập. Nếu quay về Compose cũ có tunnel, nó có thể
  khởi động lại connector cũ; chỉ giữ hai connector nếu cả hai truy cập được mọi origin.

Tài liệu tham khảo: [Docker external networks](https://docs.docker.com/reference/compose-file/networks/),
[Cloudflare replicas](https://developers.cloudflare.com/tunnel/configuration/),
[cloudflared readiness command](https://github.com/cloudflare/cloudflared/blob/master/cmd/cloudflared/tunnel/subcommands.go).
