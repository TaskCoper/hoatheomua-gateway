# Routing — HoaTheoMua API Gateway

Tài liệu này mô tả **logic định tuyến (routing)** của API Gateway: một request đi vào được khớp, biến đổi đường dẫn, và chuyển tiếp tới backend nào. Gateway được xây trên [YARP](https://microsoft.github.io/reverse-proxy/) và **toàn bộ routing là cấu hình, không phải code** — muốn thêm/sửa route thì sửa section `ReverseProxy` trong `appsettings*.json` (hoặc env var tương đương), không cần sửa C#.

> File liên quan: `Program.cs`, `DependencyInjection/Extensions/ServiceCollectionExtensions.cs`, `HoaTheoMua.ApiGateway/appsettings.json`, `appsettings.Development.json`.

---

## 1. Tổng quan luồng request

```
                                   ┌─────────────────────────────────────────────┐
                                   │            API Gateway (:8080)                │
 Client ──▶ (Cloudflare Tunnel) ──▶│      YARP định tuyến (proxy thuần, no auth)  │
                                   │                                    │         │
                                   └────────────────────────────────────┼─────────┘
                                                                        │
                              ┌──────────────── Route match ────────────┤
                              │                                         │
                  Path: ecommerce-api/**                    Path: taskcoper-api/**
                              │                                         │
                  Transform: api/**                          Transform: api/**
                              │                                         │
                              ▼                                         ▼
                  ecommerceApiCluster                        taskcoperApiCluster
                  http://hoatheomua-api-dev:8080/   http://htm-taskcoper-api-dev:8080/
```

Pipeline trong `Program.cs` cực kỳ tối giản — gateway là **proxy thuần, KHÔNG có middleware authn/authz**:

```
builder.Services.AddReverseProxyApiGateway(...)   ─▶   app.MapReverseProxy()
```

YARP được nạp bằng `AddReverseProxy().LoadFromConfig(configuration.GetSection("ReverseProxy"))`. Vì dùng `LoadFromConfig`, mọi thay đổi route đều nằm ở cấu hình.

---

## 2. Hai khái niệm cốt lõi: Route và Cluster

Định tuyến YARP gồm 2 phần, ghép với nhau qua `ClusterId`:

| Khái niệm   | Trả lời câu hỏi                              | Thành phần chính                          |
| ----------- | ------------------------------------------- | ----------------------------------------- |
| **Route**   | Request *nào* khớp, và đi tới cluster nào?   | `Match.Path`, `Transforms`, `ClusterId`   |
| **Cluster** | Cluster đó *đẩy về backend* ở đâu?           | `Destinations[].Address`                  |

- **Route** = điều kiện khớp đường dẫn vào (public) + phép biến đổi đường dẫn + tên cluster đích.
- **Cluster** = danh sách địa chỉ backend thật. Có thể có nhiều `Destination` (YARP tự cân tải), hiện tại mỗi cluster chỉ có 1.

---

## 3. Bảng route hiện tại

| Route               | Khớp đường dẫn vào (`Match.Path`) | Cluster đích          | Biến đổi (`PathPattern`) | Backend (Destination)                  |
| ------------------- | --------------------------------- | --------------------- | ------------------------ | -------------------------------------- |
| `ecommerceApiRoute` | `ecommerce-api/{**catch-all}`     | `ecommerceApiCluster` | `api/{**catch-all}`      | `http://hoatheomua-api-dev:8080/`      |
| `taskcoperApiRoute` | `taskcoper-api/{**catch-all}`     | `taskcoperApiCluster` | `api/{**catch-all}`      | `http://htm-taskcoper-api-dev:8080/`   |

Cả hai route dùng **cùng một khuôn mẫu**: lấy một *prefix công khai* để chọn backend, rồi thay prefix đó bằng `api/` trước khi chuyển tiếp.

---

## 4. Cơ chế khớp & biến đổi đường dẫn

### `{**catch-all}` là gì?

Đây là **catch-all route parameter** của YARP. Nó khớp **toàn bộ phần còn lại** của đường dẫn sau prefix, *kể cả dấu `/`*. Giá trị bắt được sẽ được "tái sử dụng" trong `PathPattern` để dựng đường dẫn gửi xuống backend.

- `Match.Path: ecommerce-api/{**catch-all}` → khớp mọi request bắt đầu bằng `/ecommerce-api/`.
- `PathPattern: api/{**catch-all}` → đường dẫn mới = `api/` + đúng phần đã bắt được.

Tức là: **prefix `ecommerce-api` / `taskcoper-api` chỉ đóng vai trò "bộ chọn" (selector)** để gateway biết gửi tới backend nào. Bản thân backend **luôn chỉ nhìn thấy `api/...`** — nó không hề biết tới prefix công khai.

### Ví dụ biến đổi cụ thể

| Client gọi Gateway                         | Route khớp          | Backend nhận được (URL đầy đủ)                                  |
| ------------------------------------------ | ------------------- | -------------------------------------------------------------- |
| `GET /ecommerce-api/products/42`           | `ecommerceApiRoute` | `GET http://hoatheomua-api-dev:8080/api/products/42`           |
| `GET /ecommerce-api/orders?status=paid`    | `ecommerceApiRoute` | `GET http://hoatheomua-api-dev:8080/api/orders?status=paid`    |
| `POST /taskcoper-api/tasks`                | `taskcoperApiRoute` | `POST http://htm-taskcoper-api-dev:8080/api/tasks`             |
| `GET /taskcoper-api/tasks/9/subtasks`      | `taskcoperApiRoute` | `GET http://htm-taskcoper-api-dev:8080/api/tasks/9/subtasks`   |
| `GET /unknown/foo`                         | *(không khớp)*      | `404` — không route nào match                                  |

Lưu ý:
- **Query string** (`?status=paid`) được giữ nguyên, đi kèm theo.
- **Method, headers, body** được chuyển tiếp nguyên trạng; chỉ có *path prefix* bị viết lại.
- Đường dẫn không khớp prefix nào → không có route → trả về `404`.

---

## 5. Routing theo môi trường (env override)

Địa chỉ backend trong `appsettings.json` và `appsettings.Development.json` hiện **giống hệt nhau** (đều dùng tên service Docker). Vì vậy **file JSON không phải là thứ phân biệt môi trường** — chúng chỉ là giá trị mặc định/local.

Khác biệt thật giữa các môi trường được tiêm vào lúc deploy qua **biến môi trường** (ASP.NET dùng `__` để lồng cấp). `Program.cs` gọi `AddEnvironmentVariables()` *sau cùng*, nên env var **đè lên** JSON:

```
ReverseProxy__Clusters__ecommerceApiCluster__Destinations__Destination1__Address  =  ${ADDRESS_ECOMMERCE}
ReverseProxy__Clusters__taskcoperApiCluster__Destinations__Destination1__Address  =  ${ADDRESS_TASKCOPER}
```

`${ADDRESS_ECOMMERCE}` / `${ADDRESS_TASKCOPER}` lấy từ `.docker/.env` (xem `.docker/.env.sample`) và được map trong các compose file. Nhờ vậy **cùng một bộ route, backend đổi theo môi trường** mà không cần sửa code hay JSON.

> ⚠️ Vì JSON mặc định trỏ tới hostname Docker (`hoatheomua-api-dev`, `htm-taskcoper-api-dev`), nếu một môi trường **không** chạy trên mạng Docker chung và **không** set `ADDRESS_ECOMMERCE`/`ADDRESS_TASKCOPER`, gateway sẽ không resolve được hostname và route sẽ fail. Luôn đảm bảo set các env này ở môi trường ngoài Docker network.

---

## 6. Routing và Authentication — cố tình KHÔNG có ở gateway

Gateway là **proxy thuần**: **không authenticate, không authorize**. Không có middleware JWT/auth nào trong `Program.cs`. Mọi request khớp route đều được forward nguyên trạng — header `Authorization` (nếu có) được YARP **chuyển tiếp mặc định** xuống backend.

➡️ **Authn/authz do từng service downstream tự lo:** mỗi service tự validate token được forward và tự phân quyền. Vì service expose cổng `8080` trong Docker network (có thể bị gọi thẳng, bỏ qua gateway), service **không được tin gateway** — phải tự kiểm token; gateway không phải lưới an toàn.

Nếu sau này muốn authenticate ở biên: thêm lại `AddAuthentication`/`UseAuthentication` trong `Program.cs` và gắn `AuthorizationPolicy` cho từng route trong cấu hình YARP (`ReverseProxy:Routes:<route>:AuthorizationPolicy`), nhớ để các path public như login/health là `anonymous`.

---

## 7. Hướng dẫn thêm một route mới

Ví dụ: thêm service `payment` để `/payment-api/...` → `http://hoatheomua-payment-dev:8080/api/...`.

**Bước 1 — Thêm Route + Cluster** vào `ReverseProxy` (cả `appsettings.json` và `appsettings.Development.json`):

```jsonc
"Routes": {
  "paymentApiRoute": {
    "ClusterId": "paymentApiCluster",
    "Match": { "Path": "payment-api/{**catch-all}" },
    "Transforms": [ { "PathPattern": "api/{**catch-all}" } ]
  }
},
"Clusters": {
  "paymentApiCluster": {
    "Destinations": {
      "Destination1": { "Address": "http://hoatheomua-payment-dev:8080/" }
    }
  }
}
```

**Bước 2 — Thêm env var tương đương** cho deploy (trong các compose file dưới `.docker/`, theo đúng kiểu route hiện có):

```
ReverseProxy__Routes__paymentApiRoute__ClusterId: paymentApiCluster
ReverseProxy__Routes__paymentApiRoute__Match__Path: payment-api/{**catch-all}
ReverseProxy__Routes__paymentApiRoute__Transforms__0__PathPattern: api/{**catch-all}
ReverseProxy__Clusters__paymentApiCluster__Destinations__Destination1__Address: ${ADDRESS_PAYMENT}
```

**Bước 3 — Khai báo biến địa chỉ** `ADDRESS_PAYMENT` trong `.docker/.env.sample` (và set giá trị thật trong `.docker/.env` + secrets của môi trường deploy).

**Bước 4 — Đảm bảo kết nối mạng:** backend mới phải nằm trên Docker network mà gateway truy cập được (xem network `hoatheomua-network-dev` trong `.docker/compose.yaml`), hoặc đặt `ADDRESS_PAYMENT` trỏ tới địa chỉ có thể resolve.

> Quy tắc: mỗi khi thêm service downstream, sửa **3 nơi đồng bộ** — cấu hình route/cluster (JSON hoặc env `__`), biến địa chỉ trong `.docker/.env.sample`, và secret địa chỉ ở workflow deploy nếu cần.

---

## 8. Tóm tắt nhanh

- **Route chọn backend qua prefix; Transform biến `<prefix>/...` thành `api/...`.** Backend luôn chỉ thấy `api/...`.
- **`{**catch-all}`** mang nguyên phần còn lại của path (kể cả `/`) sang URL backend; query string giữ nguyên.
- **JSON = mặc định, env var = sự thật khi deploy.** Backend đổi theo môi trường qua `ReverseProxy__Clusters__...__Address`.
- **Gateway cố tình không authn/authz** — mỗi service tự lo; gateway chỉ forward, header `Authorization` được chuyển tiếp sẵn xuống backend.
