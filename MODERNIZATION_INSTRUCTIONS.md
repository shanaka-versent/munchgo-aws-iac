# MunchGo Modernization Instructions

> I have a legacy monolith at `munchgo-monolith/`. Read and understand the entire codebase first — every entity, service, controller, state machine, and security rule. Then modernize it following these instructions.

---

## The Monolith

Java 8 / Spring Boot 2.3 / Thymeleaf MVC / MySQL 8 / Spring Security (form-based, BCrypt) / Flyway / single JAR on port 8080. Five domain entities (Consumer, Restaurant, MenuItem, Courier, Order), four roles (CUSTOMER, RESTAURANT_OWNER, COURIER, ADMIN), six MVC controllers, value objects (Money, Address, PersonName), and an order state machine (APPROVAL_PENDING through to DELIVERED, with REJECTED and CANCELLED branches).

---

## 1. Decompose into Microservices

Upgrade to Java 21, Spring Boot 3.2, PostgreSQL 16. Create a multi-module Maven project with shared DDD libraries (aggregate root base class, value objects, standard API response wrapper, global exception handler, and a transactional outbox for reliable event publishing to Kafka) and six services — each with its own database and Flyway migrations:

| Service | Bounded Context | Notes |
|---------|----------------|-------|
| Auth Service | Identity & tokens | Thin facade over managed IdP — never validates tokens itself |
| Consumer Service | Consumer profiles | Auto-creates profile when a user registers |
| Restaurant Service | Restaurants & menus | Validates order items and minimum amounts |
| Courier Service | Availability & delivery | Handles async courier assignment from saga |
| Order Service | Order lifecycle | **CQRS + Event Sourcing** — event store for writes, denormalized view for reads |
| Saga Orchestrator | Distributed order creation | Coordinates all services to place an order end-to-end |

Use CQRS + Event Sourcing only for the Order Service. The rest are standard CRUD. Don't over-engineer.

The saga uses a hybrid pattern: synchronous HTTP with circuit breakers for validation steps, asynchronous Kafka for courier assignment. Compensation reverses completed steps on failure.

Every service publishes domain events through the transactional outbox — events are written to the database in the same transaction as the domain change, then relayed to Kafka asynchronously. This guarantees no events are lost.

Wrap all REST responses in a standard envelope. Write unit tests for every service and controller.

---

## 2. Event-Driven Architecture

Use Kafka as the event backbone. Services communicate through domain event topics (one per service) plus dedicated command/reply topics for saga orchestration. Enable producer idempotence for exactly-once semantics.

---

## 3. Authentication

Replace form-based auth with a managed identity provider — Amazon Cognito on AWS, Azure AD B2C on Azure. Map the four monolith roles to IdP groups. Inject role claims into JWT tokens so the API gateway can enforce access control. The auth-service stores a local user reference (no password — that lives in the IdP) and publishes registration events so downstream services can auto-create profiles.

---

## 4. AWS Infrastructure

Provision with Terraform: VPC, EKS, IAM with IRSA and GitHub OIDC federation, load balancer controller, container registries, managed Kafka (MSK), RDS PostgreSQL (single instance with per-service databases), Cognito, S3 for the SPA, CloudFront + WAF, ArgoCD, and Transit Gateway for private connectivity to Kong Cloud Gateway.

CloudFront is mandatory — WAF is mandatory and it sits on CloudFront. Protect the origin so no one can bypass CloudFront & WAF to hit Kong directly (origin mTLS + custom header validation).

Sync cloud secrets into Kubernetes via External Secrets Operator. No secrets in Git.

Scripts to provision the entire platform and tear down the environment cleanly.

---

## 5. Azure Infrastructure

Provision the equivalent with Terraform: resource group, VNet, AKS, Key Vault with workload identity, container registry, Event Hubs (Kafka-compatible), PostgreSQL Flexible Server, Azure Storage for SPA, AD B2C, Azure Front Door + WAF (mandatory), GitHub OIDC federation, and ArgoCD. Use VNet Peering for Kong connectivity.

Same secrets pattern with Key Vault as backend. Same provisioning and teardown scripts.

---

## 6. Kubernetes & GitOps

Create a separate GitOps repository with Kustomize base/overlays for dev, staging, and prod environments. Each service gets its own overlay so CI can update image tags independently. ArgoCD syncs each service with automated prune and self-heal.

Deploy all platform components (Istio, External Secrets, observability, mesh policies) through ArgoCD App of Apps with ordered sync waves so dependencies install in the right sequence.

---

## 7. Service Mesh

Deploy Istio Ambient mesh — zero-sidecar architecture with automatic mTLS on all pod-to-pod traffic and L7 authorization policies controlling which services can communicate. Enforce strict mutual TLS (no plaintext). The Istio Gateway with an internal load balancer serves as the single entry point from Kong into the mesh.

---

## 8. API Gateway

Kong Cloud Gateway handles external traffic with path-based routing into the mesh. OIDC plugin validates JWTs from the IdP and forwards identity claims as upstream headers. Auth endpoints are public, restaurant browsing allows anonymous access, everything else requires authentication. Per-route rate limiting and CORS enforcement.

---

## 9. CI/CD Pipelines

GitHub Actions workflow per service plus one for shared library changes. Pipeline stages: build & test → build container image (Jib, no Dockerfile) → push to primary registry → sync to cloud registries → update GitOps repo with new image tag. Use OIDC federation for cloud auth (no stored credentials). Common library changes trigger a rebuild of all services. Include manual trigger for re-runs.

---

## 10. Observability

Deploy Prometheus + Grafana for metrics, Jaeger for distributed tracing, and Kiali for service mesh topology visualization. All services expose health and metrics endpoints via Spring Boot Actuator.

---

## 11. API Testing

Create an Insomnia collection with a one-click end-to-end runner that tests the full order lifecycle — from user registration through to order delivery. After-response scripts auto-chain variables between requests so the whole flow runs unattended. Include standalone request folders for testing individual service endpoints.

---

## 12. SPA Frontend

Build a React SPA served from object storage behind the CDN. API calls route through the CDN to Kong (no cache), static assets get long-lived immutable caching, and the index.html is always served fresh.

---

## Security — Defense in Depth

Five layers, edge to application:

1. **CDN + WAF** — DDoS protection, OWASP rules, IP reputation, rate limiting
2. **Origin protection** — Prevent bypassing CDN to reach the gateway directly
3. **API Gateway** — JWT validation, per-route rate limiting, CORS
4. **Service Mesh** — Automatic mutual TLS, service-to-service authorization policies
5. **Application** — Input validation, domain business rules

No secrets in Git. OIDC federation for all CI/CD. External Secrets Operator for cloud-to-Kubernetes secret sync.

---

## Key Design Decisions

- Database-per-service with single PostgreSQL instance (logical isolation, can split later)
- CQRS + Event Sourcing only where the complexity justifies it (Order Service)
- Hybrid saga: synchronous HTTP for fast validation, asynchronous Kafka for assignment
- Transactional Outbox over CDC (simpler, self-contained, no extra infrastructure)
- Istio Ambient over sidecar injection (zero resource overhead)
- Managed API gateway over self-hosted (less operational burden)
- Containerless builds (Jib) over Dockerfiles (reproducible, no daemon)
- Multi-registry strategy: primary registry synced to cloud-specific registries

---

## Repositories

| Repository | Purpose |
|------------|---------|
| `munchgo-monolith` | Source — the legacy app to modernize |
| `munchgo-microservices` | Microservices source code + CI/CD workflows |
| `munchgo-k8s-config` | Kubernetes manifests + ArgoCD apps |
| `munchgo-aws-iac` | AWS infrastructure, platform scripts, Kong config, API test collection |
| `munchgo-azure-iac` | Azure infrastructure (same structure) |
| `munchgo-spa` | Frontend SPA |
