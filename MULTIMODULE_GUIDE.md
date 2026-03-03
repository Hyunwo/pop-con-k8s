# 멀티모듈 전환 가이드

현재 싱글 모듈 Spring Boot 프로젝트를 **Gradle 멀티모듈**로 전환하는 가이드입니다.
각 서비스가 독립적인 Docker 이미지로 빌드되어 k3s / EKS에 개별 배포됩니다.

---

## 목차

1. [왜 멀티모듈인가](#1-왜-멀티모듈인가)
2. [목표 구조](#2-목표-구조)
3. [Gradle 설정](#3-gradle-설정)
4. [common 모듈 설계](#4-common-모듈-설계)
5. [서비스 간 통신 전환](#5-서비스-간-통신-전환)
6. [application.yml 분리](#6-applicationyml-분리)
7. [각 서비스 Dockerfile](#7-각-서비스-dockerfile)
8. [GitHub Actions - 변경된 모듈만 빌드](#8-github-actions---변경된-모듈만-빌드)
9. [전환 순서 (권장)](#9-전환-순서-권장)

---

## 1. 왜 멀티모듈인가

| | 싱글 모듈 | 멀티모듈 |
|--|-----------|----------|
| 배포 단위 | 전체 서비스 1개 | 서비스별 독립 배포 |
| 이미지 | 1개 | 서비스 수만큼 |
| 장애 격리 | 한 서비스 문제 → 전체 영향 | 해당 서비스만 영향 |
| 스케일링 | 전체 스케일 아웃 | 필요한 서비스만 스케일 아웃 |
| 빌드 시간 | 항상 전체 빌드 | 변경된 모듈만 빌드 |

EKS 전환을 고려할 때, 서비스별 독립 배포와 스케일링이 핵심입니다.

---

## 2. 목표 구조

```
popcon/                              ← 단일 Git 레포 (모노레포)
 ├── settings.gradle                 ← 모듈 등록
 ├── build.gradle                    ← 공통 의존성 (BOM, 플러그인)
 │
 ├── common/                         ← 공통 라이브러리 (독립 실행 불가)
 │     ├── build.gradle
 │     └── src/main/java/com/t1/popcon/common/
 │            ├── entity/            (BaseEntity 등)
 │            ├── exception/         (공통 예외)
 │            └── response/          (ApiResponse 등)
 │
 ├── auth-service/                   ← 독립 실행 가능한 서비스
 │     ├── build.gradle
 │     ├── Dockerfile
 │     └── src/
 │            ├── main/java/com/t1/popcon/auth/
 │            │      └── AuthApplication.java
 │            └── main/resources/
 │                   └── application.yml  (포트: 8081)
 │
 ├── user-service/
 │     ├── build.gradle
 │     ├── Dockerfile
 │     └── src/
 │            ├── main/java/com/t1/popcon/user/
 │            │      └── UserApplication.java
 │            └── main/resources/
 │                   └── application.yml  (포트: 8082)
 │
 └── ticket-service/
       ├── build.gradle
       ├── Dockerfile
       └── src/
              ├── main/java/com/t1/popcon/ticket/
              │      └── TicketApplication.java
              └── main/resources/
                     └── application.yml  (포트: 8083)
```

---

## 3. Gradle 설정

### settings.gradle (루트)

```groovy
rootProject.name = 'popcon'

include 'common'
include 'auth-service'
include 'user-service'
include 'ticket-service'
```

### build.gradle (루트) - 공통 설정

```groovy
plugins {
    id 'java'
    id 'org.springframework.boot' version '3.x.x' apply false  // apply false: 루트에선 미적용
    id 'io.spring.dependency-management' version '1.x.x' apply false
}

// 모든 서브모듈에 적용
subprojects {
    apply plugin: 'java'
    apply plugin: 'io.spring.dependency-management'

    group = 'com.t1.popcon'
    version = '0.0.1-SNAPSHOT'

    java {
        sourceCompatibility = JavaVersion.VERSION_21
    }

    repositories {
        mavenCentral()
    }

    dependencyManagement {
        imports {
            mavenBom "org.springframework.boot:spring-boot-dependencies:3.x.x"
        }
    }

    dependencies {
        // 모든 모듈 공통 의존성
        compileOnly 'org.projectlombok:lombok'
        annotationProcessor 'org.projectlombok:lombok'
        testImplementation 'org.springframework.boot:spring-boot-starter-test'
    }
}
```

### common/build.gradle

```groovy
// common은 독립 실행 불가 → bootJar 비활성화
bootJar { enabled = false }
jar { enabled = true }       // 다른 모듈이 참조할 수 있도록 일반 jar 생성

dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
    implementation 'org.springframework.boot:spring-boot-starter-web'
}
```

### auth-service/build.gradle

```groovy
apply plugin: 'org.springframework.boot'

// auth-service는 실행 가능한 jar
bootJar { enabled = true }

dependencies {
    implementation project(':common')   // common 모듈 참조

    implementation 'org.springframework.boot:spring-boot-starter-web'
    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
    implementation 'org.springframework.boot:spring-boot-starter-security'
    // ... auth 관련 의존성
}
```

> `user-service`, `ticket-service`도 동일한 패턴으로 작성

---

## 4. common 모듈 설계

### common에 넣어야 하는 것

```
common/src/main/java/com/t1/popcon/common/
 ├── entity/
 │    └── BaseEntity.java          (createdAt, updatedAt 등 공통 필드)
 ├── exception/
 │    ├── BusinessException.java   (공통 예외 클래스)
 │    └── ErrorCode.java           (공통 에러 코드 enum)
 ├── response/
 │    └── ApiResponse.java         (공통 응답 형식)
 └── util/
      └── (공통 유틸 클래스)
```

### common에 넣으면 안 되는 것

```
❌ 특정 서비스의 도메인 로직 (User, Auth, Ticket 관련 클래스)
❌ 특정 서비스에서만 쓰는 외부 API 클라이언트
❌ 서비스 간 순환 의존성이 생기는 코드
```

---

## 5. 서비스 간 통신 전환

> **가장 중요한 단계**입니다. 현재 같은 패키지 안에서 메서드를 직접 호출하는 코드를
> 서비스 간 HTTP 통신으로 전환해야 합니다.

### 현재 (직접 호출)

```java
// AuthService.java 내부
@RequiredArgsConstructor
public class AuthService {
    private final UserService userService;  // ← 직접 의존

    public void login(String email) {
        User user = userService.findByEmail(email);  // 직접 호출
        // ...
    }
}
```

### 전환 후 (HTTP 통신 - RestClient)

```java
// auth-service 내부의 UserClient.java
@Component
public class UserClient {

    private final RestClient restClient;

    public UserClient(RestClient.Builder builder) {
        this.restClient = builder
            .baseUrl("http://user-service:8082")  // k8s Service 이름 사용
            .build();
    }

    public UserResponse findByEmail(String email) {
        return restClient.get()
            .uri("/internal/users?email={email}", email)
            .retrieve()
            .body(UserResponse.class);
    }
}
```

```java
// user-service 내부의 InternalUserController.java
@RestController
@RequestMapping("/internal/users")
public class InternalUserController {

    private final UserService userService;

    @GetMapping
    public UserResponse findByEmail(@RequestParam String email) {
        return userService.findByEmail(email);
    }
}
```

### k8s Service 이름 규칙

k8s에서 같은 네임스페이스 내 서비스는 **서비스명으로 DNS 조회** 가능합니다.

```
http://auth-service:8081
http://user-service:8082
http://ticket-service:8083
```

---

## 6. application.yml 분리

### 현재 (단일 application.yml)

```yaml
server:
  port: 8080
spring:
  datasource:
    url: jdbc:mysql://${DB_HOST}:${DB_PORT}/${DB_NAME}
```

### 전환 후 - 각 서비스마다 독립 설정

**auth-service/src/main/resources/application.yml**
```yaml
server:
  port: 8081          # auth 서비스 포트

spring:
  datasource:
    url: jdbc:mysql://${DB_HOST}:${DB_PORT}/popcon_auth
    username: ${DB_USERNAME}
    password: ${DB_PASSWORD}
  jpa:
    hibernate:
      ddl-auto: validate
```

**user-service/src/main/resources/application.yml**
```yaml
server:
  port: 8082          # user 서비스 포트

spring:
  datasource:
    url: jdbc:mysql://${DB_HOST}:${DB_PORT}/popcon_user
```

> DB를 서비스별로 분리할지(권장) 단일 DB로 유지할지는 팀에서 결정 필요.
> 초기에는 단일 DB에 스키마만 분리하는 것도 방법입니다.

---

## 7. 각 서비스 Dockerfile

각 서비스 루트에 동일한 패턴으로 작성합니다.

**auth-service/Dockerfile**

```dockerfile
# 1. 빌드 단계
FROM eclipse-temurin:21-jdk-jammy AS build
WORKDIR /app

# 루트 Gradle 설정 복사 (멀티모듈이므로 루트 설정 필요)
COPY gradlew .
COPY gradle gradle
COPY settings.gradle .
COPY build.gradle .

# auth-service 모듈 파일 복사
COPY common/build.gradle common/build.gradle
COPY auth-service/build.gradle auth-service/build.gradle

# 의존성 다운로드 (캐시 활용)
RUN chmod +x gradlew && ./gradlew :auth-service:dependencies --no-daemon

# 소스 코드 복사 및 빌드
COPY common/src common/src
COPY auth-service/src auth-service/src
RUN ./gradlew :auth-service:bootJar -x test --no-daemon \
    && rm -f auth-service/build/libs/*-plain.jar

# 2. 실행 단계
FROM eclipse-temurin:21-jre-jammy
WORKDIR /app

RUN groupadd -r appgroup && useradd -r -g appgroup appuser

COPY --from=build --chown=appuser:appgroup /app/auth-service/build/libs/*.jar app.jar

ENV SPRING_PROFILES_ACTIVE=prod
ENV JAVA_OPTS="-Xms512m -Xmx512m"

USER appuser
EXPOSE 8081

ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

> `user-service`, `ticket-service`도 동일 패턴 (모듈명과 포트만 변경)

---

## 8. GitHub Actions - 변경된 모듈만 빌드

멀티모듈에서 핵심은 **변경된 서비스만 빌드/배포**하는 것입니다.
`paths` 필터를 사용합니다.

**.github/workflows/build-auth.yml**

```yaml
name: Build Auth Service

on:
  push:
    branches: [ dev ]
    paths:
      - 'auth-service/**'   # auth-service 변경 시만 실행
      - 'common/**'         # common 변경 시도 auth 재빌드

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-northeast-2

      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: auth-${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/dev-app:$IMAGE_TAG -f auth-service/Dockerfile .
          docker push $ECR_REGISTRY/dev-app:$IMAGE_TAG

      # GitOps 레포 이미지 태그 업데이트 (ArgoCD 자동 배포 트리거)
      - name: Update image tag in GitOps repo
        env:
          IMAGE_TAG: auth-${{ github.sha }}
        run: |
          git clone https://x-access-token:${{ secrets.GITOPS_TOKEN }}@github.com/<org>/pop-con-k8s.git
          cd pop-con-k8s
          sed -i "s|image: .*dev-app:auth-.*|image: $ECR_REGISTRY/dev-app:$IMAGE_TAG|" \
            k8s/overlays/prod/auth-patch.yaml
          git config user.email "github-actions@github.com"
          git config user.name "github-actions"
          git commit -am "chore: update auth-service image to $IMAGE_TAG"
          git push
```

> `user-service`, `ticket-service`도 동일 패턴으로 각각 워크플로우 파일 작성

---

## 9. 전환 순서 (권장)

작업을 한꺼번에 하면 충돌과 혼란이 생깁니다. 단계별로 진행하세요.

```
Step 1   현재 코드에서 서비스 간 의존성 파악
          → auth, user, ticket이 서로 어떤 메서드를 호출하는지 목록화

Step 2   common 모듈 분리
          → BaseEntity, ApiResponse, 공통 예외만 먼저 common으로 이동
          → 나머지는 아직 그대로 유지

Step 3   settings.gradle, 루트 build.gradle 작성
          → 멀티모듈 Gradle 구조 세팅

Step 4   서비스 코드 이동 (서비스 하나씩)
          → auth부터 시작, 빌드 확인 후 user, ticket 순서로

Step 5   서비스 간 직접 호출 → HTTP 통신 전환
          → 가장 시간이 걸리는 단계, 신중하게 진행

Step 6   각 서비스 Dockerfile 작성 및 로컬 빌드 확인

Step 7   GitHub Actions 워크플로우 수정
```