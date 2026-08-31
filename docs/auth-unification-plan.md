# Auth Unification — Full Context & Implementation Handoff

> **Status: IMPLEMENTED (2026-06-20).** Both backends build clean; hoatheomua-be migrations reset to a single `Initial_ResourceServer`. Two manual steps remain before end-to-end testing — see **"Remaining manual steps"** directly below.
>
> ### Remaining manual steps (deploy/runtime — cannot be done in code)
> 1. **Set identical JWT values for both services.** `taskcoper-be` and `hoatheomua-be` must receive the **same** `JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_ACCESS_TOKEN_KEY` (→ `JwtOption__*`). taskcoper-be owns the canonical values; copy them into hoatheomua-be's `.docker/.env` (and the matching GitHub environment secrets). Note: taskcoper-be has **no committed appsettings.json** — it is env-only; hoatheomua-be's `appsettings.json` still carries dev fallbacks (`Issuer/Audience="HoaThuaMua"`) that are overridden by env at deploy. For **local** cross-service testing, run both via their Docker `.env` so they share the same three values.
> 2. **Wipe & reseed the hoatheomua-be dev DB.** `dotnet ef database drop -f -p HoaTheoMua.Repository -s HoaTheoMua.API`, then start the API (startup `MigrateAsync` recreates the schema). The old DB still has the pre-reset migration history, so it must be dropped once.
>
> Optional cleanup: hoatheomua-be's real `.docker/.env` (gitignored) still contains now-unused `MAIL_*`, `JWT_REFRESH_TOKEN_KEY`, `JWT_*_EXPIRE_MIN`, `SECURITY_PEPPER` vars — harmless (nothing references them) but can be deleted.

> This is a self-contained handoff doc — it captures the full background, the decisions and their rationale, the current state of all three repos (with file paths), and the step-by-step plan.
>
> **Repos involved** (siblings under `/Users/user/Documents/WorkSpace/hoatheomua-paid/`):
> - `hoatheomua-gateway` — YARP API gateway (this repo)
> - `hoatheomua-be` — e-commerce backend (.NET 8, layered)
> - `taskcoper-be` — task/mentoring backend (.NET 8, Clean Architecture)

---

## 1. Background & how we got here

### 1.1 The gateway is now a pure pass-through (already done)
`hoatheomua-gateway` is a .NET 8 **YARP reverse proxy**. Over this work it was reduced to a **pure pass-through**: all JWT/authentication/authorization was removed from it (code, config, compose, CI). It now only matches routes, rewrites the path, and forwards — including the `Authorization` header, which YARP forwards by default.

Routing (see `docs/routing.md`):
| Incoming | Cluster | Rewritten to | Backend |
|---|---|---|---|
| `ecommerce-api/{**catch-all}` | ecommerceApiCluster | `api/{**catch-all}` | hoatheomua-be |
| `taskcoper-api/{**catch-all}` | taskcoperApiCluster | `api/{**catch-all}` | taskcoper-be |

**Consequence for this plan:** the gateway needs **no change**. A token issued by taskcoper-be reaches either backend unchanged.

### 1.2 Why auth lives in the services, not the gateway
We discussed where authn/authz should sit. Conclusions that shaped this plan:
- **Authentication** (is the token real?) *can* sit at the edge, but with catch-all routing the gateway can't see individual endpoints, so it can only do coarse, token-only checks.
- **Authorization** (what can this identity do on this resource?) *must* live in the service — only the service knows its endpoints and domain (e.g. "does user X own order #42"). The gateway can't add per-endpoint policy without duplicating each service's URL structure (coupling, brittle).
- **JWT claims are the shared contract.** Both services read the same token; neither needs the gateway to know their APIs.
- **Decision:** the gateway does nothing for auth; **each service validates the token and enforces its own authz**. Services are reachable directly on the Docker network (port `8080`), so they must not trust the gateway as a safety net — they validate independently.

### 1.3 The problem this plan solves
Two divergent identity systems exist:
- `hoatheomua-be` — its own simplistic auth (custom `User` table, JWT issuance, roles `Admin/User/Staff`).
- `taskcoper-be` — a complete auth system (JWT issuance + Redis refresh tokens, email verification, roles `User/Mentor/Lecturer/Admin`, multi-tenant orgs).

**Goal:** unify on **one** system. `taskcoper-be` becomes the **sole token issuer**; `hoatheomua-be` becomes a **pure resource server** that only validates taskcoper-be's tokens. Delete hoatheomua-be's `User` table and its whole token-issuance subsystem. Preserve hoatheomua-be's profile display via a **snapshot** copied from JWT claims at write time. Add hoatheomua-be's `Staff` role into taskcoper-be.

---

## 2. Decisions locked with the user

| # | Decision | Choice | Impact |
|---|---|---|---|
| 1 | Existing data | **Dev stage — wipe & reseed** | No row migration; reset EF migrations, drop FKs, recreate. |
| 2 | Scope in hoatheomua-be | **Full teardown** | Remove login/register/verify/refresh/forgot + `RefreshToken`/`ForgotPassword` tables; validate-only. |
| 3 | Profile display after User table is gone | **Snapshot pattern** | Copy actor's profile from JWT claims onto each record at write time; no User table, no read-time cross-service call. |
| 4 | hoatheomua's `Staff` role (absent in taskcoper) | **Add `Staff` to taskcoper-be** | New role + policy + assignment path in taskcoper-be. |

**Derived requirement from #3:** taskcoper-be's token currently carries only `UserId`, `Email`, `Role`, `IsVerified` — **no name/avatar**. To snapshot a meaningful profile, taskcoper-be must **enrich the token with `FullName` + `Avatar` claims** (its `User` entity already has those fields). This is folded into Workstream 1.

---

## 3. Current state — findings (so you don't re-explore)

### 3.1 taskcoper-be (the standard / issuer)
- **Layout:** Clean Architecture under `src/` — `taskcoper-be.api` (Program.cs, JWT setup, middleware), `.presentation` (Carter endpoints), `.application` (MediatR handlers), `.domain` (entities), `.infrastructure` (JWT service, password hasher, Redis, mail), `.persistence` (EF Core + migrations), `.contract` (DTOs, constants). .NET 8, EF Core 8 + PostgreSQL, Redis, Carter, MediatR.
- **JWT setup:** `src/taskcoper-be.api/dependencyInjection/extensions/JwtExtensions.cs` — HS256 symmetric, `ValidateIssuer/Audience/Lifetime/IssuerSigningKey = true`, `ClockSkew = Zero`, `SaveToken = true`, cookie fallback (`accessToken`), rich `OnChallenge`/`OnForbidden` JSON responses.
- **JwtOption:** `src/taskcoper-be.application/dependencyInjection/options/JwtOption.cs` — `Issuer, Audience, AccessTokenKey, AccessTokenExpireMin, RefreshTokenKey, RefreshTokenExpireMin`. Env keys: `JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_ACCESS_TOKEN_KEY`, etc.
- **User entity:** `src/taskcoper-be.domain/entities/User.cs` — `FirstName, LastName, Email, HashedPassword, Role (string), Avatar, OrganizationId, IsEmailVerified, …`. Custom (no ASP.NET Identity). PBKDF2-SHA256 hashing.
- **Token issuance:** `src/taskcoper-be.application/usecases/queries/user/GetLoginQueryHandler.cs` builds claims: `ClaimTypes.Email`, `ClaimTypes.Role` + custom `"Role"`, `"UserId"`, `"Email"`, `ClaimTypes.Name`(=email), `"Timezone"`, `ClaimTypes.Expired`, `"OrganizationId"`, `"IsVerified"` ("true"/"false"). **No FirstName/LastName/Avatar claim.** Refresh tokens in Redis (`SessionTokenStore.cs`), rotated. Verify also issues a token: `usecases/commands/user/AccountVerifyFirstTimeCommandHandler.cs`.
- **Policies:** `JwtExtensions.cs` — `DefaultPolicy = RequireAuthenticatedUser + RequireClaim("IsVerified","true")`; named: `AuthenticatedOnly`, `ChangePassword`, `User`, `Mentor`, `Lecturer`, `Admin`, `MentorOrLecturer`, `SystemAdmin`. Role constants: `src/taskcoper-be.contract/constants/RoleNames.cs`. **No `Staff`.**
- **Roles issued:** `User, Mentor, Lecturer, Admin` (Register defaults `Role = request.Role==0 ? "User" : "Mentor"`).

### 3.2 hoatheomua-be (to convert)
- **Layout:** `HoaTheoMua.API` (Controllers, Program.cs, `Extentions/JwtExtensions.cs`, `Extentions/CookieExtensions.cs`), `HoaTheoMua.Service` (per-feature `Service.cs`: Auth, Order, Config, New, CategoryNew, RecruitmentRequests, Product, JobDescriptions, CompanyAddress, Webhook, Ahamove, Mail, Jwt, User, + `Exceptions/`), `HoaTheoMua.Repository` (`Entity/`, `AppDbContext.cs`, `Configurations/`, `Enum/Role.cs`, `Migrations/`, `Seeds/`). .NET 8, EF Core 8 + PostgreSQL.
- **JWT setup:** `HoaTheoMua.API/Extentions/JwtExtensions.cs` — HS256 symmetric, validates Issuer/Audience/Lifetime/SigningKey, `NameClaimType = NameIdentifier`, `RoleClaimType = Role`, cookie read `HTM-Access-Token`. **No `ClockSkew=Zero` (defaults to 5 min).**
- **JwtOption:** `HoaTheoMua.Service/JwtService/JwtOption.cs` — same 6 fields. **Values differ from taskcoper:** `appsettings.json` has `Issuer/Audience = "HoaThuaMua"`, `AccessTokenKey = "IRanUIwukUBzSauFsZnr7AjV7XS96keke"`. Default builder overlays env vars, so `JwtOption__*` env wins at deploy.
- **Token issuance:** `HoaTheoMua.Service/Auth/Service.cs` + `JwtService/Service.cs` (`GenerateAccessToken`). Claims: `"UserId"`, `ClaimTypes.Role`, **`"IsVerify"`** (note: different name from taskcoper's `"IsVerified"`). Refresh tokens stored in DB (`RefreshToken` table). Endpoints in `HoaTheoMua.API/Controllers/UserController.cs`: `/api/v1/auth/{register,verify-email,re-send-mail,refresh,sign-out,sign-in,me}`.
- **Policies:** `HoaTheoMua.API/Extentions/JwtExtensions.cs` — `DefaultPolicy = RequireAuthenticatedUser + RequireClaim("IsVerify")`; named: `AdminPolicy`, `StaffPolicy`, `UserPolicy`, `StaffOrAdminPolicy`, `UserVerifiedPolicy`. `Role` enum (`HoaTheoMua.Repository/Enum/Role.cs`) = `Admin, User, Staff`. Only `AdminPolicy` is actually used by controllers (grep).
- **Program.cs:** runs `await dbContext.Database.MigrateAsync()` on startup; pipeline `UseAuthentication → UseAuthorization → MapControllers`.

### 3.3 User-table dependency map (the hard part)
8 entities have FK `UserId → Users`, all declared in `HoaTheoMua.Repository/Configurations/UserConfiguration.cs`:

| Entity | Delete behavior | Notes |
|---|---|---|
| RefreshToken | Cascade | deleted entirely (auth teardown) |
| ForgotPassword | Cascade | deleted entirely |
| AuditLog | Cascade (nullable) | keep table, drop FK; unused by services |
| CategoryNews | Restrict | keep `UserId`, drop FK/nav |
| News | Cascade | keep `UserId`, drop FK/nav; **shows author profile** |
| Order | Cascade | keep `UserId`, drop FK/nav |
| Config | Cascade | keep `UserId`, drop FK/nav |
| RecruitmentRequest | Cascade | keep `UserId`, drop FK/nav; **shows author profile** |

**Services that query `_dbContext.Users` or read the `UserId` claim:**
- `Order/Service.cs` — filters `Orders` by `UserId`; **validates** `Users.FirstOrDefault(x.Id==userId && x.IsVerify)` exists (CreateOrder, GetStatusOrder).
- `Config/Service.cs` — **validates** `Users.AnyAsync(x.Id==userId)` (GetConfigById, CreateConfig).
- `New/Service.cs` — `.Include(n => n.User)` and projects `news.User.{Email,Avatar,FirstName,LastName}` into responses.
- `RecruitmentRequests/Service.cs` — `.Include(r => r.User)` and projects user fields into responses.
- `CategoryNew/Service.cs` — `GetUserId()` helper reading the `"UserId"` claim; stores `UserId` only (no User join).
- `Auth/Service.cs` — login/register/verify/refresh/getMe/forgot all query `Users` (to be deleted).

### 3.4 Compatibility gaps (issuer ↔ validator)
| Gap | taskcoper issues | hoatheomua expects | Action |
|---|---|---|---|
| Secret/Issuer/Audience | its `JWT_*` values | `"HoaThuaMua"` + own key | **Must be identical** (Workstream 3) |
| Verified claim | `"IsVerified"` | `"IsVerify"` | hoatheomua → `"IsVerified"` |
| User id claim | `"UserId"` | `"UserId"` | ✓ compatible |
| Role claim | `ClaimTypes.Role` | `ClaimTypes.Role` | ✓ (`Admin`/`User` match) |
| `Staff` role | not issued | needed | add `Staff` to taskcoper |
| name/avatar | not in token | needed for snapshot | enrich token (FullName/Avatar) |
| ClockSkew | Zero | 5 min default | align to Zero (optional) |

---

## 4. Target architecture

```
Login  ─▶ taskcoper-be  (issues JWT: UserId, Email, Role, IsVerified, + NEW: FullName, Avatar)
                │ token
   ┌────────────┴───────────────┐
   ▼                            ▼
taskcoper-be                hoatheomua-be
(validate + own authz)      (validate only; snapshot profile onto records)
        shared HS256 key / Issuer / Audience
                ▲
        gateway forwards Authorization header unchanged (no auth logic)
```

---

## 5. Implementation plan

### Workstream 1 — taskcoper-be (issuer): add Staff + enrich token
1. **Add `Staff` role**
   - `src/taskcoper-be.contract/constants/RoleNames.cs` — add `public const string Staff = nameof(Staff);`
   - `src/taskcoper-be.api/dependencyInjection/extensions/JwtExtensions.cs` — add `opts.AddPolicy(RoleNames.Staff, p => p.RequireRole(RoleNames.Staff));` (optionally a `StaffOrAdmin` mirroring hoatheomua's `StaffOrAdminPolicy`).
   - **Role assignment:** `RegisterCommandHandler.cs` hardcodes `User`/`Mentor`. For dev, seed the needed `Staff`/`Admin` accounts directly (or add an Admin-only "set role" endpoint) — dev seed is enough to unblock.
2. **Enrich issued token** (feeds the snapshot)
   - `src/taskcoper-be.application/usecases/queries/user/GetLoginQueryHandler.cs` — also select `FirstName, LastName, Avatar`; add `new Claim("FullName", $"{FirstName} {LastName}")` and `new Claim("Avatar", avatar ?? "")`.
   - `src/taskcoper-be.application/usecases/commands/user/AccountVerifyFirstTimeCommandHandler.cs` — add the same claims (it also issues a token).
   - Refresh (`GetTokenQueryHandler.cs`) reuses cached-token claims → propagates automatically.
3. **Config** — taskcoper-be owns the canonical `JWT_ISSUER`/`JWT_AUDIENCE`/`JWT_ACCESS_TOKEN_KEY` (Workstream 3). No code change.

> taskcoper's `DefaultPolicy` requires `IsVerified=true`; its `OrganizationId` claim is irrelevant to hoatheomua-be and is ignored there.

### Workstream 2 — hoatheomua-be: convert to resource server

**2A. Auth teardown**
- Delete folders: `HoaTheoMua.Service/Auth/`, `HoaTheoMua.Service/JwtService/` (keep only a slimmed `JwtOption.cs`), `HoaTheoMua.Service/MailService/`, `HoaTheoMua.Service/User/` (empty shell).
- Delete `HoaTheoMua.API/Controllers/UserController.cs`.
- `Program.cs`: remove DI registrations + `using` aliases for Auth/JwtService/MailService/UserService. Keep `AddJwtServices`, `AddHttpContextAccessor`.
- **Before deleting `Auth/`:** move `Auth/Validations/JobDescriptionRequestValidator.cs` → `JobDescriptions/Validations/` (auto-registered by `AddValidatorsFromAssembly`, `Program.cs:68`; otherwise JD validation silently disappears).
- **Do NOT delete** `HoaTheoMua.Service/Exceptions/` (used by surviving services + `JwtExtensions.cs`).
- Cookies (`CookieExtensions.cs`): remove `WriteAuthCookies`/`DeleteAuthCookies`/`RefreshTokenCookieName`. Prefer the `Authorization: Bearer` header; if cookie auth is needed, align `AccessTokenCookieName` to taskcoper's `accessToken`.

**2B. Validation-only JWT — `HoaTheoMua.API/Extentions/JwtExtensions.cs`**
Keep the 5 policies + symmetric-key `TokenValidationParameters`. Only changes:
- `RequireClaim("IsVerify")` → `RequireClaim("IsVerified")` (DefaultPolicy, ~line 74).
- `RequireClaim("IsVerify", "true")` → `RequireClaim("IsVerified", "true")` (UserVerifiedPolicy, ~line 93).
- (Optional) add `ClockSkew = TimeSpan.Zero` to match taskcoper.
- `Staff` now issuable from taskcoper; no controller uses `StaffPolicy` today, so non-blocking.

**2C. Data model / EF (wipe & reset)**
- Drop `Users`, `RefreshTokens`, `ForgotPasswords`: delete `Entity/User.cs`, `Entity/RefreshToken.cs`, `Entity/ForgotPassword.cs`; remove their `DbSet`s in `AppDbContext.cs`; delete `Configurations/UserConfiguration.cs` (removes all 8 FKs at once), `RefreshTokenConfiguration.cs`, `ForgotPasswordConfiguration.cs`; delete their seeds.
- Keep `Guid UserId` as a plain external-id column on the 6 survivors (`News, CategoryNews, Order, Config, RecruitmentRequest, AuditLog`); delete the `User`/`User?` navigation prop on each. Add `HasIndex(x => x.UserId)` where queried (Order).
- AuditLog: keep with plain `UserId`, delete `AuditLogSeed.cs` (references gone users). Or drop AuditLog entirely if unused.
- **Snapshot columns** (from enriched token): add to `News` and `RecruitmentRequest`: `AuthorName`, `AuthorEmail`, `AuthorAvatar` (nullable). `UserId` is the author id. Order/Config/CategoryNews expose only `UserId` — no snapshot.
- **Migration = RESET:** make all model edits first, delete the `Migrations/` folder, drop the dev DB, then `dotnet ef migrations add Initial_ResourceServer`. `MigrateAsync()` applies on boot. Update surviving seeds (`NewsSeed.cs`) to populate `Author*`.

**2D. Service rewrites**
Add a shared `ICurrentUserService` (`HoaTheoMua.Service/Common/CurrentUserService.cs`) over `IHttpContextAccessor`: `GetUserId()`, `GetEmail()`, `GetFullName()`, `GetAvatar()`, `IsVerified()`. Register `AddScoped`. Then:
- `Order/Service.cs` — replace `Users.FirstOrDefault(x.Id==userId && x.IsVerify)` checks with `IsVerified()` claim check; keep `Orders.Where(x.UserId == userId)` via `GetUserId()`; delete dead commented blocks.
- `Config/Service.cs` — remove `Users.AnyAsync(...)` checks; keep setting `UserId` from claim.
- `New/Service.cs` — drop `.Include(n => n.User)`; on create set `AuthorName/Email/Avatar` from claims; in responses use snapshot columns. Update `New/Response.cs`.
- `RecruitmentRequests/Service.cs` — drop `.Include(r => r.User)`; write snapshot on create; read snapshot in responses. Update `RecruitmentRequests/Response.cs`.
- `CategoryNew/Service.cs` — swap local `GetUserId()` for the shared service; delete commented `_dbContext.Users` block.
- **Final grep** for `_dbContext.Users`, `.RefreshTokens`, `.ResetPasswords`, `.Include(*User*)`, `news.User`, `x.User` → empty outside deleted files.

**2-config. JwtOption**
Slim `JwtService/JwtOption.cs` to `Issuer`, `Audience`, `AccessTokenKey`. Reduce the `JwtOption` block in both `appsettings*.json` to those 3 keys; remove `MailOption` and `SecurityOption` (Pepper). Dev values must equal taskcoper-be's.

### Workstream 3 — shared config / deploy
- Both services receive **identical** `JWT_ISSUER`, `JWT_AUDIENCE`, `JWT_ACCESS_TOKEN_KEY` (env → `JwtOption__*`). hoatheomua-be no longer needs `JWT_REFRESH_TOKEN_KEY`/expiry/`MailOption__*` — remove them from `hoatheomua-be/.docker/docker-compose.yml` (+ overlays) and CI (`.github/workflows/deploy-application.yaml`).
- Source shared values from one place (deploy secrets) so they can't drift; taskcoper-be owns the canonical values.
- Gateway: no change.

---

## 6. Verification (end-to-end)
1. **Reset DB:** `dotnet ef database drop -f -p HoaTheoMua.Repository -s HoaTheoMua.API`; start API → `MigrateAsync` recreates schema. psql check: no `Users`/`RefreshTokens`/`ForgotPasswords`; `News` has `AuthorEmail/AuthorName/AuthorAvatar` + plain `UserId` (no FK).
2. **Token from taskcoper-be:** login → decode token; confirm `UserId, Email, Role, IsVerified=true, FullName, Avatar`.
3. **Authed write to hoatheomua-be** (direct): `POST /api/v1/news` (needs `Role=Admin`) with `Authorization: Bearer <token>` → 201. Row has `UserId` = claim, `Author*` = claims. `GET` back → snapshot shown, no User join, no cross-service call.
4. **Verified-gating:** token with `IsVerified=false` → rejected (proves `IsVerify`→`IsVerified`).
5. **Through gateway:** same token to `…/ecommerce-api/v1/orders` → identical result (proves header forwarding).
6. **Negative:** token signed with a different key / wrong issuer → 401.

---

## 7. Ordering & risks
1. Make all model/service/config edits **before** regenerating EF migrations.
2. Reset migration avoids manual FK-drop ordering; `MigrateAsync` on boot means a broken migration crashes startup — review the generated migration first.
3. **Highest-risk change:** `IsVerify`→`IsVerified` in 2 policy lines + the Order existence checks. Miss one → valid tokens silently rejected on verified-gated endpoints.
4. Relocate `JobDescriptionRequestValidator` before deleting `Auth/`.
5. Do not delete `Service/Exceptions/`.
6. Snapshot completeness depends on Workstream 1 token enrichment landing first (else `AuthorName/Avatar` are null).

## 8. Open follow-ups (post-unification, not blocking)
- Productionize Staff/Admin role assignment in taskcoper-be (admin endpoint) vs dev seeding.
- Decide cookie-vs-header auth for browser clients; align cookie names if needed.
- Consider whether hoatheomua-be users need to be migrated/created in taskcoper-be (dev: just seed the accounts you test with).

---

## 9. Key files quick-reference
**taskcoper-be**
- `src/taskcoper-be.api/dependencyInjection/extensions/JwtExtensions.cs` — policies; add `Staff`.
- `src/taskcoper-be.contract/constants/RoleNames.cs` — add `Staff`.
- `src/taskcoper-be.application/usecases/queries/user/GetLoginQueryHandler.cs` — add FullName/Avatar claims.
- `src/taskcoper-be.application/usecases/commands/user/AccountVerifyFirstTimeCommandHandler.cs` — same.

**hoatheomua-be**
- `HoaTheoMua.API/Extentions/JwtExtensions.cs` — `IsVerify`→`IsVerified`, validation-only.
- `HoaTheoMua.API/Program.cs` — remove deleted services' DI/usings.
- `HoaTheoMua.Repository/AppDbContext.cs` — drop 3 DbSets.
- `HoaTheoMua.Repository/Configurations/UserConfiguration.cs` — delete (removes all 8 FKs).
- `HoaTheoMua.Service/{Order,Config,New,RecruitmentRequests,CategoryNew}/Service.cs` — rewrites.
- `HoaTheoMua.Service/Common/CurrentUserService.cs` — new shared claim reader.
- `HoaTheoMua.Service/JwtService/JwtOption.cs` — slim to 3 fields.
- delete: `HoaTheoMua.Service/{Auth,MailService,User}/`, `JwtService/Service.cs`, `HoaTheoMua.API/Controllers/UserController.cs`.

**gateway**: no change. Routing reference in `docs/routing.md`.
