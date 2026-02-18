# MunchGo Modernization Instructions

> Use this file as instructions for Claude to modernize the `munchgo-monolith` application into a production-grade, multi-cloud microservices platform. The monolith is located at `munchgo-monolith/` — read and understand it fully before starting.

---

## What I Have

I have a legacy Java monolith called **MunchGo** — a food delivery platform. It's built with:

- Java 8, Spring Boot 2.3, Thymeleaf (server-side MVC), MySQL 8, Spring Security (form-based login with BCrypt), Flyway migrations
- 5 domain entities: Consumer, Restaurant, MenuItem, Courier, Order (with state machine)
- 4 roles: ROLE_CUSTOMER, ROLE_RESTAURANT_OWNER, ROLE_COURIER, ROLE_ADMIN
- 6 MVC controllers (Auth, Customer, RestaurantOwner, Courier, Admin, Browse)
- Value objects: Money, Address, PersonName
- Single JAR deployment on port 8080

Read the monolith source code thoroughly. Understand every entity, service, controller, state transition, and security rule before proceeding.

---

## What I Want You to Build

Modernize this monolith into the following. Work through each section in order.

---

## 1. Create the Microservices Project

Create a new multi-module Maven project called `munchgo-microservices` with this structure:

```
munchgo-microservices/
├── pom.xml                           (parent POM)
├── munchgo-common/                   (shared libraries, POM packaging)
│   ├── munchgo-common-domain/        (DDD building blocks)
│   ├── munchgo-common-events/        (event infrastructure)
│   ├── munchgo-common-web/           (REST API utilities)
│   └── munchgo-common-messaging/     (transactional outbox pattern)
├── munchgo-auth-service/             (port 8086, db: munchgo_auth)
├── munchgo-consumer-service/         (port 8081, db: munchgo_consumers)
├── munchgo-restaurant-service/       (port 8082, db: munchgo_restaurants)
├── munchgo-courier-service/          (port 8083, db: munchgo_couriers)
├── munchgo-order-service/            (port 8084, db: munchgo_orders)
└── munchgo-order-saga-orchestrator/  (port 8085, db: munchgo_sagas)
```

**Parent POM requirements:**
- Java 21, Spring Boot 3.2.1, Spring Cloud 2023.0.0
- Dependencies: spring-boot-starter-web, spring-boot-starter-data-jpa, spring-boot-starter-validation, spring-boot-starter-actuator, spring-kafka 3.1.1, postgresql 42.7.1, flyway-core 10.4.1, resilience4j 2.2.0, mapstruct 1.5.5, lombok 1.18.30, testcontainers 1.19.3
- Plugins: maven-compiler (Java 21 with Lombok + MapStruct annotation processors), spring-boot-maven-plugin, surefire (`**/*Test.java`), failsafe (`**/*IT.java`), jib-maven-plugin 3.4.0 (base image: `eclipse-temurin:21-jre-alpine`, JVM flags: `-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0`)
- Maven profiles: `dev` (default, `ddl-auto: create-drop`, show SQL), `prod` (`ddl-auto: validate`, minimal logging), `integration-test` (runs Failsafe)
- Set `<jib.skip>true</jib.skip>` in `munchgo-common/pom.xml` so Jib doesn't try to containerize the library modules (they have no main class)

**All services use PostgreSQL** (not MySQL). Each service gets its own logical database. Use Flyway for schema migrations.

---

## 2. Shared Libraries (munchgo-common)

### munchgo-common-domain

Build DDD building blocks:

- **AggregateRoot** base class: pre-generate UUID `id` in constructor (available before persistence), `@Version` for optimistic locking, JPA auditing (`createdAt`, `updatedAt`), domain event registration (`registerEvent()`, `getDomainEvents()`, `clearDomainEvents()`), implements Spring `Persistable<UUID>` for `isNew()` detection
- **DomainEvent** marker interface with `getEventId()`, `getOccurredAt()`, `getAggregateId()`, `getAggregateType()`
- **Money** value object: immutable, BigDecimal with scale 2 and HALF_UP rounding, arithmetic (`add`, `subtract`, `multiply`), comparison, currency support (default USD), factory method `Money.of(amount)`
- **PersonName**: embeddable, firstName + lastName
- **Address**: embeddable, street1, street2, city, state, zip, country

### munchgo-common-events

Event transport infrastructure:

- **BaseDomainEvent** abstract class: auto-generates UUID eventId and Instant occurredAt, stores aggregateId, aggregateType, eventType
- **DomainEventEnvelope\<T\>**: wraps event with metadata for Kafka transport (eventId, eventType, aggregateType, aggregateId, occurredAt, payload, metadata). Factory: `wrap(event)`
- **EventMetadata**: correlation/causation tracking
- **ResultWithEvents\<T\>**: wraps command result + emitted domain events

### munchgo-common-web

REST API utilities:

- **ApiResponse\<T\>**: standard response wrapper `{ success: boolean, data: T, error: ErrorResponse }`. Factory methods: `ApiResponse.success(data)`, `ApiResponse.error(message, code)`
- **GlobalExceptionHandler** (`@RestControllerAdvice`): `ResourceNotFoundException` → 404, `BusinessException` → 400, generic Exception → 500. Returns `ApiResponse<ErrorResponse>`
- **ResourceNotFoundException**, **BusinessException**

### munchgo-common-messaging

Implement the **Transactional Outbox** pattern:

- **OutboxEvent** JPA entity (table: `outbox_events`): fields — aggregateType, aggregateId, eventType, topic (Kafka topic), eventKey (partition key), payload (TEXT/JSON), published (boolean), publishedAt, retryCount, lastError. Methods: `markAsPublished()`, `recordFailure(error)`
- **OutboxEventPublisher**: `@Transactional(propagation = MANDATORY)` — must join existing transaction. Wraps event in DomainEventEnvelope, serializes to JSON, inserts into outbox_events. Methods: `publish(topic, event)`, `publish(topic, key, event)`, `publishAll(topic, events)`
- **OutboxRelay**: `@Scheduled(fixedDelay = 100ms)` — polls unpublished events (max retries 5, batch 100), publishes to Kafka, marks as published. Nightly cleanup cron: deletes published events older than 7 days
- **OutboxRepository**: JPA repository with `findUnpublishedWithRetryLimit(maxRetries)`, `countByPublishedFalse()`, `deletePublishedEventsBefore(cutoff)`
- **KafkaConfig**: producer idempotence enabled, String key/value serializers

Every service that publishes events must include `outbox_events` table in its Flyway migrations.

---

## 3. Consumer Service

Decompose the Consumer bounded context from the monolith.

**Domain:** `Consumer` entity extending AggregateRoot. Embedded PersonName and Address. Fields: email (unique), phoneNumber, active (boolean). Factory method `Consumer.create()` that registers `ConsumerCreatedEvent`. Update method registers `ConsumerUpdatedEvent`.

**API endpoints:**
- POST `/api/v1/consumers` — create consumer
- GET `/api/v1/consumers/{id}` — get consumer
- GET `/api/v1/consumers` — list all
- PUT `/api/v1/consumers/{id}` — update consumer
- PUT `/api/v1/consumers/{id}/address` — update address
- POST `/api/v1/consumers/{id}/validate` — validate consumer exists and is active (used by saga orchestrator)
- POST `/api/v1/consumers/{id}/deactivate` — deactivate
- POST `/api/v1/consumers/{id}/activate` — activate

Publish events to `consumer-events` Kafka topic via the outbox.

Add a Kafka listener on `user-events` topic that auto-creates a consumer profile when a user registers with ROLE_CUSTOMER.

Use MapStruct for DTO mapping. Wrap all responses in `ApiResponse<T>`.

**Important:** Put `@EnableJpaRepositories` and `@EntityScan` annotations on a separate `JpaConfig.java` class (not on the main `@SpringBootApplication` class). This prevents `@WebMvcTest` from bootstrapping the full JPA context during controller tests.

**Tests:** Write unit tests for the controller (`@WebMvcTest` with MockMvc, `@MockBean` for service layer) covering all endpoints, validation errors, and exception handling. Write unit tests for the service layer with mocked repositories.

---

## 4. Restaurant Service

Decompose the Restaurant bounded context.

**Domain:** `Restaurant` entity extending AggregateRoot. Fields: name, description, minimumOrderAmount (Money), address (Address). Child entity `MenuItem` with name, description, price (Money), available (boolean). Methods: `addMenuItem()`, `removeMenuItem()`, `updateMenuItem()`, `validateOrder(lineItems)` — checks all items available and order total >= minimumOrderAmount.

**API endpoints:**
- POST `/api/v1/restaurants` — create restaurant
- GET `/api/v1/restaurants/{id}` — get restaurant
- GET `/api/v1/restaurants` — list all (public, no auth required)
- POST `/api/v1/restaurants/{id}/menu-items` — add menu item
- POST `/api/v1/restaurants/{id}/validate-order` — validate order line items and total (used by saga)

Seed "MunchGo Burger Palace" with 7 menu items via Flyway migration V3.

Publish events to `restaurant-events` topic via the outbox.

Write tests for controller and service layers.

---

## 5. Courier Service

Decompose the Courier bounded context.

**Domain:** `Courier` entity extending AggregateRoot. Fields: firstName, lastName, email, phoneNumber, address (Address), available (boolean). Methods: `assign(orderId)`, `release()`, `setAvailability(boolean)`.

**API endpoints:**
- POST `/api/v1/couriers` — create courier
- GET `/api/v1/couriers/{id}` — get courier
- POST `/api/v1/couriers/{id}/availability` — update availability

**Saga integration:** Create a `SagaCommandHandler` that listens on `saga-commands` Kafka topic. When it receives an `AssignCourier` command, find the first available courier and reply on `saga-replies` topic with success (courierId) or failure. Also handle `ReleaseCourier` for compensation.

Publish events to `courier-events` topic via the outbox.

Write tests.

---

## 6. Order Service (CQRS + Event Sourcing)

This is the most complex service. Implement full **CQRS with Event Sourcing**.

### Event Store (JDBC, not JPA)

Create table:
```sql
CREATE TABLE event_store (
    id UUID PRIMARY KEY,
    aggregate_id UUID NOT NULL,
    aggregate_type VARCHAR(100) NOT NULL,
    event_type VARCHAR(100) NOT NULL,
    version BIGINT NOT NULL,
    payload JSONB NOT NULL,
    occurred_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT unique_aggregate_version UNIQUE (aggregate_id, version)
);
```

Implement `EventStore` interface with: `appendEvents(aggregateId, aggregateType, expectedVersion, List<OrderEvent>)` with optimistic locking (check version before insert), `getEvents(aggregateId)`, `getEventsAfterVersion(aggregateId, version)`, `getCurrentVersion(aggregateId)`.

When appending events: insert into event_store, publish to outbox (`order-events` topic), and update the CQRS read model via OrderProjection — all within the same transaction.

### Command Side (Write Model)

`Order` aggregate — NOT a JPA entity. State reconstructed from events via `Order.reconstitute(id, List<OrderEvent>)`. Factory: `Order.create(CreateOrderCommand)` emits `OrderCreatedEvent`. Command methods validate current state and emit events: `approve(courierId)`, `reject(reason)`, `cancel(reason)`, `accept(readyBy)`, `notePreparing()`, `noteReadyForPickup()`, `notePickedUp()`, `noteDelivered()`.

Order events: `OrderCreatedEvent`, `OrderApprovedEvent`, `OrderRejectedEvent`, `OrderCancelledEvent`, `OrderAcceptedEvent`, `OrderPreparingEvent`, `OrderReadyForPickupEvent`, `OrderPickedUpEvent`, `OrderDeliveredEvent`.

`OrderCommandService`: loads aggregate from event store, applies command, appends new events.

Command endpoints: POST `/api/v1/orders` (create), POST `/api/v1/orders/{id}/approve`, POST `/api/v1/orders/{id}/reject`, POST `/api/v1/orders/{id}/cancel`.

### Query Side (Read Model)

`OrderView` JPA entity (table: `order_views`): denormalized view with id, state, consumerId, restaurantId, courierId, lineItemsJson (JSONB), totalAmount, delivery address fields, state transition timestamps, eventVersion.

`OrderProjection`: event handler that creates/updates OrderView when events are processed. Include `rebuildOrderView(orderId)` that deletes and replays all events.

`OrderQueryService`: `getOrder(orderId)`, `getOrdersByConsumer(consumerId, pageable)`, `getOrdersByRestaurant(restaurantId, pageable)`, `getOrdersByCourier(courierId, pageable)`.

Query endpoints: GET `/api/v1/orders/{id}`, GET `/api/v1/orders?consumerId=`, GET `/api/v1/orders?restaurantId=`.

### Saga Command Handler

Create a `SagaCommandHandler` Kafka listener on `saga-commands` topic. Handle `RejectOrder`, `ApproveOrder`, `CancelOrder` commands from the saga. Reply on `saga-replies` topic.

Write tests for command service, query service, event store, and projection.

---

## 7. Saga Orchestrator

Create `munchgo-order-saga-orchestrator` to coordinate the distributed order creation flow.

**CreateOrderSaga** JPA entity (table: `create_order_sagas`): fields — id, currentStep (enum), status (enum), consumerId, restaurantId, orderId, courierId, orderTotal, lineItemsJson, deliveryAddressJson, failureReason, failedStep, timestamps, version (optimistic locking).

**Saga Steps (execute in order):**
1. `VALIDATE_CONSUMER` — HTTP POST to consumer-service `/api/v1/consumers/{id}/validate` (synchronous)
2. `VALIDATE_RESTAURANT` — HTTP GET to restaurant-service `/api/v1/restaurants/{id}` (synchronous)
3. `CREATE_ORDER` — HTTP POST to order-service `/api/v1/orders` (synchronous)
4. `ASSIGN_COURIER` — Publish `AssignCourier` command to `saga-commands` Kafka topic, wait for reply on `saga-replies` (asynchronous)
5. `APPROVE_ORDER` — HTTP POST to order-service `/api/v1/orders/{id}/approve` with courierId (synchronous)
6. `COMPLETED` — terminal state

**Saga Statuses:** STARTED → IN_PROGRESS → AWAITING_REPLY → COMPLETED | COMPENSATING → FAILED

**Communication:** Use WebClient for synchronous HTTP calls. Wrap each HTTP step in Resilience4j `@CircuitBreaker` with fallback method. Timeout: 10 seconds per call.

**Compensation:** When a step fails, reverse completed steps — reject the order, release the courier.

**SagaReplyHandler:** Kafka listener on `saga-replies` topic. On success: advance saga. On failure: trigger compensation.

**API endpoints:**
- POST `/api/v1/sagas/create-order` — start saga (accepts consumerId, restaurantId, lineItems, deliveryAddress)
- GET `/api/v1/sagas/{sagaId}/status` — poll saga status (returns sagaId, status, currentStep, orderId, courierId, failureReason)

Write tests.

---

## 8. Auth Service (Cognito Integration)

Create `munchgo-auth-service` as a thin facade over Amazon Cognito. The auth-service **never validates tokens** — Kong does that at the gateway level.

**CognitoService** (AWS SDK v2):
- `register(email, password, firstName, lastName, groupName)` — AdminCreateUser + AdminSetUserPassword + AdminAddUserToGroup + AdminInitiateAuth
- `authenticate(email, password)` — AdminInitiateAuth with ADMIN_USER_PASSWORD_AUTH
- `refreshToken(refreshToken)` — REFRESH_TOKEN_AUTH flow
- `globalSignOut(email)` — AdminUserGlobalSignOut
- `getCognitoSub(email)` — AdminGetUser to get subject ID
- Use `DefaultCredentialsProvider` (picks up IRSA in EKS, env vars locally)

**AuthService** (business logic):
- Register: validate username/email uniqueness → call Cognito → save local User entity → publish `UserRegisteredEvent` to `user-events` Kafka topic via outbox
- Login: find local user → check enabled → authenticate via Cognito → return tokens + userId
- Returns `AuthResult(accessToken, idToken, refreshToken, userId)`

**User entity** (local reference only): id (UUID), email, cognitoSub, role, username, firstName, lastName, enabled. **No password field** — passwords live in Cognito only.

**API endpoints:**
- POST `/api/v1/auth/register` — register user
- POST `/api/v1/auth/login` — login (returns tokens)
- POST `/api/v1/auth/refresh` — refresh token
- POST `/api/v1/auth/logout/{userId}` — global sign-out
- GET `/api/v1/auth/profile/{userId}` — get user profile

**Cognito User Pool Groups:** ROLE_CUSTOMER, ROLE_RESTAURANT_OWNER, ROLE_COURIER, ROLE_ADMIN

Write tests mocking CognitoService and OutboxEventPublisher.

---

## 9. Kafka Topics

Configure these 7 Kafka topics across the services:

| Topic | Publisher | Consumer(s) |
|-------|-----------|-------------|
| `user-events` | Auth Service | Consumer Service, Courier Service |
| `consumer-events` | Consumer Service | (external) |
| `restaurant-events` | Restaurant Service | (external) |
| `courier-events` | Courier Service | (external) |
| `order-events` | Order Service | (external) |
| `saga-commands` | Saga Orchestrator | Order Service, Courier Service |
| `saga-replies` | Order Service, Courier Service | Saga Orchestrator |

Producer config: `acks=all`, `retries=3`, `enable.idempotence=true`. Consumer config: `group-id=${spring.application.name}`, `auto-offset-reset=earliest`.

---

## 10. CI/CD Pipelines (GitHub Actions)

Create 7 GitHub Actions workflows in `.github/workflows/`:

**Per-service workflows** (auth-service.yml, consumer-service.yml, restaurant-service.yml, courier-service.yml, order-service.yml, order-saga-orchestrator.yml):

Each workflow has these environment variables:
```yaml
env:
  SERVICE_MODULE: munchgo-order-service        # Maven module name
  SERVICE_NAME: munchgo-order-service          # Container image name
  GITOPS_DIR: order-service                    # k8s-config overlay directory (strips munchgo- prefix)
  JAVA_VERSION: '21'
  GHCR_REGISTRY: ghcr.io/shanaka-versent
```

Triggers: push to main (path-filtered to service + common + pom.xml) + `workflow_dispatch` for manual re-runs.

**Pipeline stages:**

1. **Build & Test:** `mvn -pl munchgo-common,${{ env.SERVICE_MODULE }} -am clean verify` (the `-am` flag is critical to build common dependencies)
2. **Push to GHCR:** `mvn -pl munchgo-common,${{ env.SERVICE_MODULE }} -am compile jib:build` with image tag = git SHA
3. **Sync to ECR:** Use `crane copy` from GHCR to ECR (AWS OIDC federation, no stored credentials)
4. **Sync to ACR:** (conditional on `vars.AZURE_ACR_NAME` existing) Use `crane copy` to ACR
5. **Update GitOps Repo:** Clone `munchgo-k8s-config`, run `kustomize edit set image` in `overlays/dev/${{ env.GITOPS_DIR }}/`, commit and push

Image push condition — include both push and workflow_dispatch:
```yaml
if: github.ref == 'refs/heads/main' && (github.event_name == 'push' || github.event_name == 'workflow_dispatch')
```

**GITOPS_DIR mapping** (directory names strip the `munchgo-` prefix, special case for saga):

| SERVICE_MODULE | GITOPS_DIR |
|---------------|------------|
| munchgo-auth-service | auth-service |
| munchgo-consumer-service | consumer-service |
| munchgo-restaurant-service | restaurant-service |
| munchgo-courier-service | courier-service |
| munchgo-order-service | order-service |
| munchgo-order-saga-orchestrator | saga-orchestrator |

**common-library.yml:** Triggers when `munchgo-common/` changes. Uses matrix strategy with `include` to rebuild all 6 services:
```yaml
strategy:
  matrix:
    include:
      - service: munchgo-consumer-service
        gitops_dir: consumer-service
      - service: munchgo-restaurant-service
        gitops_dir: restaurant-service
      # ... all 6 services with their gitops_dir
```

**GitOps step path:** `cd overlays/dev/${{ env.GITOPS_DIR }}` then `cd ../../..` to get back to repo root (3 levels up, not 2).

**Authentication:** GitHub → GHCR (GITHUB_TOKEN), GitHub → AWS (OIDC), GitHub → Azure (OIDC), GitHub → k8s-config repo (PAT as `GITOPS_TOKEN` secret).

---

## 11. Kubernetes GitOps Configuration

Create a separate repository `munchgo-k8s-config` with Kustomize structure:

```
munchgo-k8s-config/
├── base/
│   ├── auth-service/          (deployment.yaml, service.yaml, configmap.yaml, serviceaccount.yaml, kustomization.yaml)
│   ├── consumer-service/
│   ├── restaurant-service/
│   ├── courier-service/
│   ├── order-service/
│   └── saga-orchestrator/
├── overlays/
│   ├── dev/                   (per-service subdirectories — CI auto-updates these)
│   │   ├── auth-service/kustomization.yaml
│   │   ├── consumer-service/kustomization.yaml
│   │   ├── courier-service/kustomization.yaml
│   │   ├── order-service/kustomization.yaml
│   │   ├── restaurant-service/kustomization.yaml
│   │   └── saga-orchestrator/kustomization.yaml
│   ├── staging/kustomization.yaml    (all services, 2 replicas)
│   └── prod/kustomization.yaml       (all services, 3 replicas, higher resources)
└── argocd/
    ├── auth-service.yaml
    ├── consumer-service.yaml
    ├── restaurant-service.yaml
    ├── courier-service.yaml
    ├── order-service.yaml
    └── saga-orchestrator.yaml
```

**Base deployment template** for each service: 2 replicas, port 8080, resources (requests: 256Mi/250m, limits: 512Mi/500m), liveness + readiness probes on `/actuator/health`, env vars from ConfigMap + Secrets.

ArgoCD Applications point to `overlays/dev/<service>/` with automated sync, prune, and self-heal.

---

## 12. AWS Infrastructure (Terraform)

Create `munchgo-aws-iac` repository with Terraform modules:

| Module | What to Provision |
|--------|-------------------|
| **vpc** | VPC (10.0.0.0/16), public/private subnets (2 AZs), NAT Gateway, IGW |
| **eks** | EKS 1.29, system node pool (t3.medium with CriticalAddonsOnly taint), user node pool, OIDC provider for IRSA |
| **iam** | IRSA roles (LB Controller, External Secrets, Cognito), GitHub OIDC federation for CI/CD |
| **lb-controller** | AWS Load Balancer Controller Helm chart |
| **ecr** | 6 ECR repositories with lifecycle policies (keep 20 tagged, expire untagged after 7 days) |
| **msk** | MSK Kafka 3.6.0 (2 brokers, kafka.m5.large, 100GB EBS, 7-day retention, 3 partitions) |
| **rds** | PostgreSQL 16 (db.t3.medium), 6 logical databases, encrypted, automated backups, credentials in Secrets Manager |
| **cognito** | User Pool (email sign-in, password policy, 4 groups), App Client, Pre Token Generation Lambda v2 (injects `custom:roles` claim from group membership) |
| **spa** | S3 bucket (versioned, no public access, OAC for CloudFront) |
| **cloudfront** | CloudFront + WAF: origin mTLS to Kong (ACM client cert), WAF rules (OWASP Common, Known Bad Inputs, IP Reputation, rate limit 2000/5min), security headers (HSTS, X-Frame-Options DENY, nosniff), behaviors (/api/* → Kong no-cache, /assets/* → S3 1-year cache, / → S3 no-cache) |
| **argocd** | ArgoCD Helm v5.51.6 + argocd-apps bootstrap (App of Apps pattern) |

**Transit Gateway** for Kong Cloud Gateway connectivity: create TGW, attach EKS VPC private subnets, add route 192.168.0.0/16 → TGW, RAM share to Kong's AWS account, security group allowing Kong CIDR.

**External Secrets Operator:** ClusterSecretStore for AWS Secrets Manager, ExternalSecrets for DB credentials (per-service), Cognito config, and Kafka bootstrap servers.

**ArgoCD sync waves** (deploy in order): Gateway API CRDs (-2) → Istio Base (-1) → Istiod/CNI/Ztunnel (0) → Namespaces (1) → Istio Gateway with internal NLB (5) → HTTPRoutes (6) → Health Responder (7) → External Secrets (8) → MunchGo Apps bridge to k8s-config repo (9) → Mesh Policies (10) → Prometheus (11) → Kiali + Jaeger (12).

**CloudFront is mandatory** — WAF is mandatory and only available on CloudFront. Protect the link between CloudFront and Kong so no one directly hits Kong by bypassing CF & WAF.

---

## 13. Azure Infrastructure (Terraform)

Create `munchgo-azure-iac` repository with equivalent Terraform modules for multi-cloud:

| Module | What to Provision |
|--------|-------------------|
| **resource_group** | Logical container |
| **network** | VNet (10.0.0.0/16), AKS subnet, PostgreSQL delegated subnet, NAT Gateway, NSGs |
| **aks** | AKS 1.32, system + user node pools, Azure AD integration, OIDC issuer |
| **argocd** | ArgoCD Helm + root app bootstrap |
| **keyvault** | Azure Key Vault with RBAC |
| **workload_identity** | Managed identities + OIDC federation for pods |
| **acr** | Azure Container Registry with AcrPull |
| **eventhubs** | Kafka-compatible Event Hubs (7 topics, 3 partitions, 7-day retention, service-specific consumer groups) |
| **postgresql** | PostgreSQL Flexible Server, 6 databases, private DNS |
| **spa** | Azure Storage static website |
| **adb2c** | Azure AD B2C directory + app registration |
| **frontdoor** | Azure Front Door Premium + WAF (mandatory), X-Azure-FDID header validation to prevent Kong bypass |
| **github_oidc** | GitHub Actions OIDC federation |

Use VNet Peering (not Transit Gateway) for Kong connectivity on Azure.

Same ArgoCD sync wave pattern as AWS. Same Istio Ambient mesh configuration. Same External Secrets pattern but with Azure Key Vault as the backend.

---

## 14. Service Mesh (Istio Ambient)

Deploy Istio Ambient mesh (zero-sidecar architecture):

- **ztunnel** DaemonSet on all nodes: automatic L4 mTLS for all pod-to-pod traffic
- **istiod** control plane: distributes xDS config
- **istio-cni**: transparent proxy via iptables
- **Waypoint proxy** per namespace: L7 authorization and telemetry

**Istio Gateway** with internal NLB (AWS) or ILB (Azure): single entry point for all external traffic from Kong.

**7 HTTPRoutes** for path-based routing: `/api/v1/auth` → auth-service, `/api/v1/consumers` → consumer-service, etc. Use ReferenceGrants for cross-namespace references.

**Mesh policies:**
- PeerAuthentication: STRICT mTLS (no plaintext traffic)
- AuthorizationPolicies: allow-gateway-ingress (Kong → services), allow-saga-orchestrator (saga → other services), allow-health-checks (any → /actuator/health)
- Waypoint Gateway: `istio-waypoint` class, port 15008 HBONE protocol

**Telemetry:** Jaeger tracing (100% dev, 1-10% prod), Prometheus metrics, Envoy access logs.

---

## 15. Kong Cloud Gateway

Configure Kong as the API gateway using decK format (`deck/kong.yaml`):

| Route | Upstream Service | Auth | Rate Limit |
|-------|-----------------|------|------------|
| `/api/v1/auth` | auth-service | None (public) | 60/min |
| `/api/v1/consumers` | consumer-service | OIDC required | 100/min |
| `/api/v1/restaurants` | restaurant-service | OIDC optional (anonymous for GET) | 200/min |
| `/api/v1/orders` | order-service | OIDC required | 100/min |
| `/api/v1/couriers` | courier-service | OIDC required | 100/min |
| `/api/v1/sagas` | saga-orchestrator | OIDC required | 100/min |
| `/healthz` | health-responder | None | None |

All upstream services point to the single Istio Gateway internal NLB.

**OIDC plugin config:** issuer = Cognito `.well-known/openid-configuration`, auth_methods = bearer, cache_ttl = 300s, forward claims as upstream headers (sub → X-User-Sub, email → X-User-Email, custom:roles → X-User-Roles).

CORS plugin on all routes. Request-transformer where needed.

---

## 16. API Testing (Insomnia Collection)

Create an Insomnia collection (`insomnia/munchgo-api.json`) with:

**A "Run: Full Order Lifecycle" folder** — a one-click runner that executes 13 requests in sequence testing the entire end-to-end flow:
1. Health check
2. Register user
3. Login (capture tokens via after-response script)
4. Create consumer (capture consumer_id)
5. Create restaurant (capture restaurant_id)
6. Add menu item (capture menu_item_id)
7. Create courier (capture courier_id)
8. Set courier available
9. Create order saga (capture saga_id)
10. Poll saga status until COMPLETED (capture order_id)
11. Verify order exists
12. Accept order (restaurant)
13. Mark delivered (courier)

**After-response scripts** must handle the `ApiResponse<T>` wrapper:
```javascript
const body = insomnia.response.json();
const data = body.data || body;  // Handle both wrapped and unwrapped
const id = data.consumerId || data.id;
if (id) insomnia.environment.set('consumer_id', id);
```

Include test assertions using `insomnia.test()` and `insomnia.expect()`.

**Standalone folders** for each service with individual endpoint requests.

Set `base_url` environment variable to the CloudFront domain.

---

## 17. Observability Stack

Deploy via ArgoCD:

- **kube-prometheus-stack** Helm chart (Prometheus + Grafana + Alertmanager)
- **Jaeger** Helm chart for distributed tracing (OTLP gRPC on port 4317)
- **Kiali** Helm chart for service mesh topology visualization

All services expose Spring Boot Actuator: `management.endpoints.web.exposure.include: health,info,metrics,prometheus`.

---

## 18. Security Architecture (Defense in Depth)

Ensure 5 layers of security:

1. **Edge:** CloudFront/Front Door + WAF (DDoS, OWASP Top 10, IP reputation, rate limiting)
2. **Origin protection:** mTLS certificate (AWS) or X-Azure-FDID header (Azure) — prevent bypassing CDN/WAF to hit Kong directly
3. **API Gateway:** Kong OIDC JWT validation, per-route rate limiting, CORS
4. **Service Mesh:** Istio Ambient ztunnel (automatic mTLS with SPIFFE identities), waypoint (L7 AuthorizationPolicies, service-to-service access control)
5. **Application:** Spring validation, domain business rules

No secrets in Git. Use External Secrets Operator to sync from Secrets Manager / Key Vault. GitHub Actions uses OIDC federation (no stored AWS/Azure credentials).

---

## 19. Deployment Scripts

Create automation scripts in each IaC repo:

- `01-generate-certs.sh` — generate self-signed CA + TLS cert for Istio Gateway
- `02-setup-cloud-gateway.sh` — provision Kong Konnect, configure Transit Gateway/VNet Peering
- `03-post-terraform-setup.sh` — replace placeholder values, sync Kong deck config
- `04-seed-admin-user.sh` — create admin user in Cognito/AD B2C
- `destroy.sh` — ordered teardown

---

## Key Design Decisions

- **Database-per-service** with single PostgreSQL instance (6 logical databases)
- **CQRS + Event Sourcing** only for Order Service (other services use standard CRUD — don't over-engineer)
- **Hybrid saga:** synchronous HTTP for fast validation steps, asynchronous Kafka for courier assignment
- **Transactional Outbox** over CDC/Debezium (simpler, no extra infrastructure)
- **Istio Ambient** over sidecar (zero overhead, automatic mTLS)
- **Kong Cloud Gateway** over self-hosted (managed, connects via Transit Gateway)
- **Jib** over Dockerfile (no Docker daemon, reproducible builds)
- **GHCR as primary registry**, sync to ECR/ACR via `crane copy`
- **Per-service dev overlays** in k8s-config for independent CI updates; unified staging/prod overlays for atomic promotions

---

## Repository Map

| Repository | Purpose |
|------------|---------|
| `munchgo-monolith` | Source (legacy application to modernize) |
| `munchgo-microservices` | Microservices source code + CI/CD workflows |
| `munchgo-k8s-config` | Kubernetes manifests (Kustomize + ArgoCD apps) |
| `munchgo-aws-iac` | AWS infrastructure (Terraform + ArgoCD apps + K8s manifests + Kong deck + Insomnia) |
| `munchgo-azure-iac` | Azure infrastructure (same structure as AWS) |
| `munchgo-spa` | Frontend SPA (React/Vite) |
