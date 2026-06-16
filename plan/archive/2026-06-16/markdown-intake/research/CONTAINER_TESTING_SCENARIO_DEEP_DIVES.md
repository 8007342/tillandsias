---
title: "Container-Based Testing Scenarios: Java Testcontainers vs Rust testcontainers-rs"
author: "Claude Code"
date: 2026-05-12
status: "SCENARIO ANALYSIS"
---

# Container-Based Testing Scenarios: Deep Dives

## Overview

This document compares Java and Rust for **container-based integration testing** across six realistic scenarios. Container testing is where Java's ecosystem advantage is most pronounced.

---

## Scenario 1: PostgreSQL with Schema Initialization

### Problem
You need to test a data access layer (DAO) against a real PostgreSQL database with a specific schema, migrations, and seed data.

### Java Solution (Testcontainers + Flyway)

```java
@Testcontainers
class UserDaoIntegrationTest {
    @Container
    static PostgreSQLContainer<?> postgres = 
        new PostgreSQLContainer<>("postgres:15")
            .withDatabaseName("testdb")
            .withUsername("test")
            .withPassword("test")
            .withInitScript("init-schema.sql");  // ← Init script
    
    private UserDao dao;
    
    @BeforeEach
    void setUp() throws SQLException {
        DataSource ds = DriverManager.getConnection(
            postgres.getJdbcUrl(), 
            postgres.getUsername(), 
            postgres.getPassword()
        );
        dao = new UserDao(ds);
    }
    
    @Test
    void testInsertUser() {
        User user = new User("Alice", "alice@example.com");
        long id = dao.insert(user);
        
        Optional<User> found = dao.findById(id);
        assertThat(found)
            .isPresent()
            .get()
            .hasFieldOrPropertyWithValue("name", "Alice");
    }
    
    @Test
    void testUniqueEmailConstraint() {
        dao.insert(new User("Alice", "alice@example.com"));
        
        assertThatThrownBy(() -> 
            dao.insert(new User("Bob", "alice@example.com"))
        ).isInstanceOf(SQLException.class);
    }
}
```

**File: init-schema.sql**
```sql
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO users (name, email) VALUES ('Admin', 'admin@example.com');
```

**Advantages**:
- `withInitScript()` is built-in — no ceremony
- JDBC connection pooling automatic
- Schema + seed data loaded in one step
- Constraint validation tests are natural

**Lines of Code**: ~40 for complete test with schema

### Rust Solution (testcontainers-rs + Manual Init)

```rust
use testcontainers::{clients, images};
use postgres::Config;

#[tokio::test]
async fn test_insert_user() {
    let docker = clients::Cli::default();
    let postgres_img = images::postgres::Postgres::default()
        .with_db_name("testdb");
    let node = docker.run(postgres_img);
    
    // Manual connection setup
    let connection_string = format!(
        "postgresql://postgres:postgres@127.0.0.1:{}/testdb",
        node.get_host_port_ipv4(5432)
    );
    
    let (client, connection) = tokio_postgres::connect(
        &connection_string,
        tokio_postgres::tls::NoTls,
    )
    .await
    .unwrap();
    
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            eprintln!("connection error: {}", e);
        }
    });
    
    // Manual schema creation
    client.execute(
        "CREATE TABLE users (
            id SERIAL PRIMARY KEY,
            name VARCHAR(100) NOT NULL,
            email VARCHAR(100) NOT NULL UNIQUE,
            created_at TIMESTAMP DEFAULT NOW()
        )",
        &[],
    )
    .await
    .unwrap();
    
    // Manual seed data
    client.execute(
        "INSERT INTO users (name, email) VALUES ($1, $2)",
        &[&"Admin", &"admin@example.com"],
    )
    .await
    .unwrap();
    
    // Test insert
    let user_id: i32 = client.query_one(
        "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
        &[&"Alice", &"alice@example.com"],
    )
    .await
    .unwrap()
    .get(0);
    
    let row = client.query_one(
        "SELECT name, email FROM users WHERE id = $1",
        &[&user_id],
    )
    .await
    .unwrap();
    
    let name: String = row.get(0);
    let email: String = row.get(1);
    
    assert_eq!(name, "Alice");
    assert_eq!(email, "alice@example.com");
}
```

**Disadvantages**:
- No built-in init script support
- Manual connection pooling setup
- Schema creation is inline (verbose)
- Error handling is repetitive (`.unwrap()` everywhere)

**Lines of Code**: ~80 for equivalent test (2x Java)

### Comparison

| Aspect | Java | Rust |
|--------|------|------|
| Container setup | 5 lines | 3 lines |
| Connection pooling | Automatic (JDBC) | Manual |
| Schema init | `withInitScript()` | Manual SQL |
| Seed data | SQL file | Inline SQL |
| Error handling | Checked exceptions | `.unwrap()` or `?` |
| Total LoC | ~40 | ~80 |
| Readability | ⭐⭐⭐⭐⭐ Declarative | ⭐⭐⭐ Imperative |

**Winner**: Java (declarative model is superior for this scenario)

---

## Scenario 2: Kafka Topic Pre-creation + Producer/Consumer Test

### Problem
You need to test a Kafka producer and consumer with pre-created topics, partitions, and replication factors.

### Java Solution (Testcontainers + Spring Kafka)

```java
@Testcontainers
class KafkaIntegrationTest {
    @Container
    static KafkaContainer kafka = new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.5.0"))
        .withEnv("KAFKA_AUTO_CREATE_TOPICS_ENABLE", "false");  // Explicit topic creation
    
    private KafkaTemplate<String, User> kafkaTemplate;
    private Consumer<String, User> consumer;
    
    @BeforeEach
    void setUp() {
        String brokers = kafka.getBootstrapServers();
        
        // Producer (Spring Kafka)
        kafkaTemplate = new KafkaTemplate<>(
            new DefaultKafkaProducerFactory<>(
                Map.of(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, brokers)
            )
        );
        
        // Consumer (Spring Kafka Listener)
        ConfigurableApplicationContext context = new AnnotationConfigApplicationContext(KafkaTestConfig.class);
        context.getEnvironment().setProperty("spring.kafka.bootstrap-servers", brokers);
    }
    
    @Test
    void testProducerConsumer() throws InterruptedException {
        // Send message to pre-created topic
        kafkaTemplate.send("user-events", "key1", new User(1L, "Alice"));
        
        // Consumer processes it (via @KafkaListener in test config)
        Thread.sleep(1000);  // Wait for consumer
        
        // Verify consumer state
        assertThat(consumedUsers).containsExactly(new User(1L, "Alice"));
    }
    
    // Topic pre-creation (Testcontainers handles this via KAFKA_CREATE_TOPICS env)
    static {
        kafka.withEnv("KAFKA_CREATE_TOPICS", "user-events:3:1");  // topic:partitions:replication
    }
}

// Test config
@Configuration
class KafkaTestConfig {
    @Bean
    public ConsumerFactory<String, User> consumerFactory() {
        return new DefaultKafkaConsumerFactory<>();
    }
    
    @Bean
    public ConcurrentKafkaListenerContainerFactory<String, User> kafkaListenerContainerFactory() {
        ConcurrentKafkaListenerContainerFactory<String, User> factory =
            new ConcurrentKafkaListenerContainerFactory<>();
        factory.setConsumerFactory(consumerFactory());
        return factory;
    }
}
```

**Advantages**:
- `KAFKA_CREATE_TOPICS` env variable handles topic creation
- Spring Kafka integration is seamless
- Producer/consumer patterns are idiomatic

**Lines of Code**: ~60

### Rust Solution (testcontainers-rs + Kafka Client)

```rust
use testcontainers::{clients, images};
use rdkafka::producer::{FutureProducer, FutureRecord};
use rdkafka::consumer::{StreamConsumer, Consumer};
use rdkafka::config::ClientConfig;

#[tokio::test]
async fn test_producer_consumer() {
    let docker = clients::Cli::default();
    let kafka = docker.run(images::kafka::Kafka::default());
    
    let broker = format!("127.0.0.1:{}", kafka.get_host_port_ipv4(9092));
    
    // Manually create topic (rdkafka doesn't support AdminAPI in this version)
    let cmd_output = std::process::Command::new("docker")
        .args(&[
            "exec",
            &kafka.id(),
            "kafka-topics",
            "--create",
            "--topic", "user-events",
            "--partitions", "3",
            "--replication-factor", "1",
            "--bootstrap-server", "localhost:9092"
        ])
        .output()
        .expect("Failed to create topic");
    
    if !cmd_output.status.success() {
        eprintln!("Topic creation failed: {}", String::from_utf8_lossy(&cmd_output.stderr));
    }
    
    // Producer
    let producer: FutureProducer = ClientConfig::new()
        .set("bootstrap.servers", &broker)
        .set("message.timeout.ms", "5000")
        .create()
        .expect("Producer creation error");
    
    // Send message
    let record = FutureRecord::to("user-events")
        .key(&"key1")
        .payload(r#"{"id": 1, "name": "Alice"}"#);
    
    let _delivery_status = producer.send(record, std::time::Duration::from_secs(0)).await;
    
    // Consumer
    let consumer: StreamConsumer = ClientConfig::new()
        .set("bootstrap.servers", &broker)
        .set("group.id", "test-group")
        .set("auto.offset.reset", "earliest")
        .create()
        .expect("Consumer creation error");
    
    consumer.subscribe(&["user-events"]).expect("Can't subscribe to topics");
    
    // Consume message
    let message = consumer.recv().await.expect("No message received");
    let payload = std::str::from_utf8(message.payload().unwrap()).unwrap();
    
    assert!(payload.contains("Alice"));
}
```

**Disadvantages**:
- Topic creation requires shell execution via `docker exec`
- No built-in AdminAPI client for Kafka topics
- Manual producer/consumer configuration
- More boilerplate

**Lines of Code**: ~90 (1.5x Java)

### Comparison

| Aspect | Java | Rust |
|--------|------|------|
| Container setup | 1 line | 1 line |
| Topic pre-creation | `KAFKA_CREATE_TOPICS` env var | Manual `docker exec` |
| Producer setup | Spring Kafka (1 line) | rdkafka client (3 lines) |
| Consumer setup | `@KafkaListener` annotation | Manual StreamConsumer |
| Message sending | `kafkaTemplate.send()` | `FutureRecord` + send/await |
| Message consuming | Listener callback | Manual poll loop |
| Error handling | Checked exceptions | Result/unwrap |
| Total LoC | ~60 | ~90 |

**Winner**: Java (environment variable topic creation is vastly superior)

---

## Scenario 3: Multi-Database Testing (PostgreSQL + MongoDB + Redis)

### Problem
You need to test a service that uses three different databases simultaneously.

### Java Solution (Testcontainers Multi-Container)

```java
@Testcontainers
class MultiDatabaseIntegrationTest {
    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15");
    
    @Container
    static MongoDBContainer mongodb = new MongoDBContainer("mongo:6.0");
    
    @Container
    static GenericContainer<?> redis = new GenericContainer<>("redis:7")
        .withExposedPorts(6379);
    
    private UserRepository userRepo;        // PostgreSQL
    private ArticleRepository articleRepo;  // MongoDB
    private CacheService cacheService;     // Redis
    
    @BeforeEach
    void setUp() {
        // All three containers started automatically by @Container
        userRepo = new UserRepository(postgres.getJdbcUrl(), ...);
        articleRepo = new ArticleRepository(mongodb.getReplicaSetUrl());
        cacheService = new CacheService(redis.getHost(), redis.getFirstMappedPort());
    }
    
    @Test
    void testCrossDbOperation() {
        // Insert user in PostgreSQL
        User user = userRepo.save(new User("Alice", "alice@example.com"));
        
        // Insert article in MongoDB
        Article article = articleRepo.save(new Article("My Post", "Content", user.getId()));
        
        // Cache in Redis
        cacheService.set("article:" + article.getId(), article);
        
        // Verify cross-database consistency
        assertThat(userRepo.findById(user.getId())).isPresent();
        assertThat(articleRepo.findById(article.getId())).isPresent();
        assertThat(cacheService.get("article:" + article.getId())).isEqualTo(article);
    }
}
```

**Advantages**:
- Three `@Container` fields = three isolated, auto-started containers
- No explicit lifecycle management
- Network isolation automatic
- Cleanup automatic

**Lines of Code**: ~40

### Rust Solution (testcontainers-rs Multi-Container)

```rust
#[tokio::test]
async fn test_cross_db_operation() {
    let docker = clients::Cli::default();
    
    // Start all three containers manually
    let postgres = docker.run(images::postgres::Postgres::default());
    let mongodb = docker.run(images::mongo::Mongo::default());
    let redis = docker.run(images::redis::Redis::default());
    
    // Get connection strings
    let pg_url = format!(
        "postgresql://postgres:postgres@127.0.0.1:{}/test",
        postgres.get_host_port_ipv4(5432)
    );
    let mongo_url = format!(
        "mongodb://127.0.0.1:{}",
        mongodb.get_host_port_ipv4(27017)
    );
    let redis_addr = format!(
        "127.0.0.1:{}",
        redis.get_host_port_ipv4(6379)
    );
    
    // Connect to PostgreSQL
    let (pg_client, connection) = tokio_postgres::connect(&pg_url, NoTls)
        .await
        .expect("Failed to connect to PostgreSQL");
    tokio::spawn(async move { let _ = connection.await; });
    
    // Create table
    pg_client.execute(
        "CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100), email VARCHAR(100))",
        &[],
    )
    .await
    .expect("Failed to create table");
    
    // Insert user
    let user_id: i32 = pg_client.query_one(
        "INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id",
        &[&"Alice", &"alice@example.com"],
    )
    .await
    .expect("Failed to insert user")
    .get(0);
    
    // Connect to MongoDB
    let mongo_client = mongodb::Client::with_uri_str(&mongo_url)
        .await
        .expect("Failed to connect to MongoDB");
    let db = mongo_client.database("test");
    let articles = db.collection::<Article>("articles");
    
    // Insert article
    let article = Article {
        id: ObjectId::new(),
        title: "My Post".to_string(),
        content: "Content".to_string(),
        user_id,
    };
    articles.insert_one(&article, None).await.expect("Failed to insert article");
    
    // Connect to Redis
    let redis_conn = redis::Client::open(redis_addr)
        .expect("Failed to connect to Redis")
        .get_connection()
        .expect("Failed to get Redis connection");
    
    redis::Cmd::new()
        .arg("SET")
        .arg(format!("article:{}", article.id))
        .arg(serde_json::to_string(&article).unwrap())
        .execute(&mut redis_conn.clone());
    
    // Verify
    assert!(pg_client.query_opt(
        "SELECT * FROM users WHERE id = $1",
        &[&user_id]
    )
    .await
    .unwrap()
    .is_some());
    
    assert!(articles.find_one(doc! { "_id": article.id }, None).await.unwrap().is_some());
}
```

**Disadvantages**:
- Manual container management for all three
- Manual connection setup for each database
- No automatic schema creation
- Repetitive error handling

**Lines of Code**: ~120 (3x Java)

### Comparison

| Aspect | Java | Rust |
|--------|------|------|
| Container setup | 3 lines (`@Container` fields) | 3 manual `docker.run()` calls |
| Connection strings | Auto-generated | Manual format strings |
| Schema creation | `withInitScript()` | Manual SQL per database |
| Lifecycle | Automatic | Manual |
| Error handling | Checked exceptions | Result with `.expect()` |
| Total LoC | ~40 | ~120 |
| Readability | ⭐⭐⭐⭐⭐ Declarative | ⭐⭐⭐ Imperative |
| Test clarity | Clear intent (three DB test) | Obscured by boilerplate |

**Winner**: Java (declarative model scales to N databases)

---

## Scenario 4: Docker Compose Orchestration

### Problem
Your application uses 5+ services (web server, database, cache, message queue, search engine) defined in `docker-compose.yml`. You want to test the full stack.

### Java Solution (Testcontainers Docker Compose)

```java
@Testcontainers
class FullStackIntegrationTest {
    @Container
    static DockerComposeContainer<?> compose = new DockerComposeContainer<>(
        new File("docker-compose.test.yml"))
        .withScaledService("api", 2)  // Scale API to 2 instances
        .withExposedService("api", 8080)
        .withExposedService("db", 5432)
        .withExposedService("redis", 6379)
        .withExposedService("kafka", 9092);
    
    @Test
    void testFullStack() throws IOException, InterruptedException {
        String apiUrl = "http://" + compose.getServiceHost("api", 8080) + ":" +
                        compose.getServicePort("api", 8080);
        
        // API request
        HttpResponse<String> response = HttpClient.newHttpClient()
            .send(HttpRequest.newBuilder(URI.create(apiUrl + "/api/users"))
                .GET()
                .build(),
            HttpResponse.BodyHandlers.ofString());
        
        assertThat(response.statusCode()).isEqualTo(200);
    }
}
```

**File: docker-compose.test.yml**
```yaml
version: "3.8"
services:
  api:
    build: .
    ports:
      - "8080:8080"
    depends_on:
      - db
      - redis
      - kafka
  
  db:
    image: postgres:15
    environment:
      POSTGRES_DB: testdb
      POSTGRES_PASSWORD: test
    ports:
      - "5432:5432"
  
  redis:
    image: redis:7
    ports:
      - "6379:6379"
  
  kafka:
    image: confluentinc/cp-kafka:7.5.0
    ports:
      - "9092:9092"
```

**Advantages**:
- Single `docker-compose.yml` file defines entire stack
- Testcontainers manages orchestration
- Scaling via `.withScaledService()`
- Service discovery via `.getServiceHost()` + `.getServicePort()`

**Lines of Code**: ~25 for test + 30 for compose file

### Rust Solution (Manual Docker Compose or testcontainers-rs)

**Option 1: Manual Docker Compose**
```rust
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

#[tokio::test]
async fn test_full_stack() {
    // Start docker-compose
    let mut compose_up = Command::new("docker-compose")
        .args(&["-f", "docker-compose.test.yml", "up", "-d"])
        .spawn()
        .expect("Failed to start docker-compose");
    
    compose_up.wait().expect("docker-compose up failed");
    
    // Wait for services to be ready
    thread::sleep(Duration::from_secs(5));
    
    // Make API request
    let client = reqwest::Client::new();
    let response = client
        .get("http://localhost:8080/api/users")
        .send()
        .await
        .expect("Failed to make request");
    
    assert_eq!(response.status(), 200);
    
    // Cleanup
    let mut compose_down = Command::new("docker-compose")
        .args(&["-f", "docker-compose.test.yml", "down"])
        .spawn()
        .expect("Failed to stop docker-compose");
    
    compose_down.wait().expect("docker-compose down failed");
}
```

**Disadvantages**:
- No automatic lifecycle management (manual up/down)
- Fixed sleep instead of health checks
- No service scaling
- No service discovery (hardcoded `localhost:8080`)
- Fragile: manual cleanup can fail

**Option 2: testcontainers-rs (Manual)** — Even more verbose, requires manual module composition.

**Lines of Code**: ~50 for test (2x Java)

### Comparison

| Aspect | Java | Rust |
|--------|------|------|
| Compose file | Standard docker-compose.yml | Standard docker-compose.yml |
| Container start | Automatic (@Container) | Manual Command::new() |
| Service discovery | `.getServiceHost()` API | Hardcoded localhost:port |
| Scaling | `.withScaledService()` | Manual compose env vars |
| Health checks | Built-in wait strategies | `sleep(Duration)` |
| Cleanup | Automatic | Manual `docker-compose down` |
| Total LoC | ~55 | ~50 (but more fragile) |

**Winner**: Java (lifecycle automation is crucial for reliability)

---

## Scenario 5: HTTP Mocking + Integration Test

### Problem
Test a service that calls external APIs (payment gateway, user service). You want to mock those APIs without hitting production.

### Java Solution (WireMock + Testcontainers)

```java
@Testcontainers
class PaymentServiceIntegrationTest {
    @Container
    static WireMockContainer wireMock = new WireMockContainer("wiremock/wiremock:3.13.2")
        .withMappingFromResource("payment-stubs.json");
    
    @Container
    static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:15");
    
    private PaymentService paymentService;
    
    @BeforeEach
    void setUp() {
        String mockUrl = "http://" + wireMock.getHost() + ":" + wireMock.getFirstMappedPort();
        paymentService = new PaymentService(mockUrl, postgres.getJdbcUrl());
    }
    
    @Test
    void testPaymentSuccess() {
        Order order = paymentService.createOrder(new OrderRequest("alice@example.com", 100.00));
        
        // WireMock responds with stubbed payment success
        PaymentResult result = paymentService.processPayment(order.getId(), "visa");
        
        assertThat(result)
            .hasFieldOrPropertyWithValue("status", "SUCCESS")
            .hasFieldOrPropertyWithValue("transactionId", "txn-12345");
    }
    
    @Test
    void testPaymentFailure() {
        Order order = paymentService.createOrder(new OrderRequest("bob@example.com", 50.00));
        
        // WireMock responds with stubbed payment failure
        PaymentResult result = paymentService.processPayment(order.getId(), "invalid-card");
        
        assertThat(result)
            .hasFieldOrPropertyWithValue("status", "FAILED")
            .hasFieldOrPropertyWithValue("errorMessage", "Invalid card");
    }
}
```

**File: payment-stubs.json**
```json
{
  "mappings": [
    {
      "request": {
        "method": "POST",
        "url": "/api/payments",
        "bodyPatterns": [
          {
            "matchesJsonPath": "$.cardType[?(@=='visa')]"
          }
        ]
      },
      "response": {
        "status": 200,
        "jsonBody": {
          "status": "SUCCESS",
          "transactionId": "txn-12345"
        }
      }
    },
    {
      "request": {
        "method": "POST",
        "url": "/api/payments",
        "bodyPatterns": [
          {
            "matchesJsonPath": "$.cardType[?(@=='invalid-card')]"
          }
        ]
      },
      "response": {
        "status": 400,
        "jsonBody": {
          "status": "FAILED",
          "errorMessage": "Invalid card"
        }
      }
    }
  ]
}
```

**Advantages**:
- Stubbing defined in JSON (data-driven)
- Dynamic stub selection based on request body
- WireMock is a real HTTP server (tests are realistic)
- No code changes to switch between mock and real API

**Lines of Code**: ~40 for test + 40 for stubs

### Rust Solution (Mockito or Manual HTTP Server)

```rust
use mockito::{mock, Mock};

#[tokio::test]
async fn test_payment_success() {
    let mut mock = mock("POST", mockito::Matcher::Regex(r"^/api/payments.*".to_string()))
        .with_header("content-type", "application/json")
        .with_body(r#"{"status": "SUCCESS", "transactionId": "txn-12345"}"#)
        .create();
    
    let mock_url = mockito::server_url();
    let payment_service = PaymentService::new(&mock_url);
    
    let order = payment_service.create_order("alice@example.com", 100.00).await.unwrap();
    let result = payment_service.process_payment(&order.id, "visa").await.unwrap();
    
    assert_eq!(result.status, "SUCCESS");
    mock.assert();
}
```

**Disadvantages**:
- Per-test mock setup (not data-driven)
- Regex matching instead of JSON path
- No JSON schema validation
- Mock creation is verbose

**Lines of Code**: ~25 per test (but harder to maintain across 10+ tests)

### Comparison

| Aspect | Java (WireMock) | Rust (mockito) |
|--------|-----------------|----------------|
| Stub definition | JSON file (data-driven) | Code per test |
| JSON path matching | ✅ Native | ❌ Regex fallback |
| Dynamic selection | ✅ Based on request body | ❌ Manual per-test |
| Reusability | ✅ Shared stubs across tests | ❌ Per-test duplication |
| Maintainability | ✅ Change stubs without code | ❌ Code changes for new scenarios |
| Server realism | ✅ Real HTTP server | ✅ Real HTTP server |

**Winner**: Java (WireMock's JSON-driven stubs are superior for maintainability)

---

## Scenario 6: Browser Automation Testing

### Problem
Test a web application across multiple browsers (Chrome, Firefox, Safari) with Selenium WebDriver.

### Java Solution (Selenium + TestNG)

```java
@Test
class WebAutomationTest {
    private static final String[] BROWSERS = {"chrome", "firefox", "safari"};
    
    @DataProvider(name = "browsers", parallel = true)
    public Object[][] getBrowsers() {
        return Stream.of(BROWSERS)
            .map(b -> new Object[]{b})
            .toArray(Object[][]::new);
    }
    
    @Test(dataProvider = "browsers")
    void testLoginAcrossBrowsers(String browser) {
        WebDriver driver = createDriver(browser);
        
        try {
            driver.get("https://example.com/login");
            
            WebElement emailField = driver.findElement(By.id("email"));
            WebElement passwordField = driver.findElement(By.id("password"));
            WebElement submitButton = driver.findElement(By.css("button[type='submit']"));
            
            emailField.sendKeys("alice@example.com");
            passwordField.sendKeys("password123");
            submitButton.click();
            
            WebDriverWait wait = new WebDriverWait(driver, Duration.ofSeconds(10));
            wait.until(ExpectedConditions.presenceOfElementLocated(By.id("dashboard")));
            
            assertThat(driver.findElement(By.id("user-name")).getText())
                .isEqualTo("Alice");
        } finally {
            driver.quit();
        }
    }
    
    private WebDriver createDriver(String browser) {
        return switch (browser) {
            case "chrome" -> new ChromeDriver();
            case "firefox" -> new FirefoxDriver();
            case "safari" -> new SafariDriver();
            default -> throw new IllegalArgumentException("Unknown browser: " + browser);
        };
    }
}
```

**File: testng.xml (XML-driven parallel execution)**
```xml
<suite name="Cross-Browser Suite" parallel="tests" thread-count="3">
    <test name="Chrome Test">
        <parameter name="browser" value="chrome"/>
        <classes>
            <class name="WebAutomationTest"/>
        </classes>
    </test>
    <test name="Firefox Test">
        <parameter name="browser" value="firefox"/>
        <classes>
            <class name="WebAutomationTest"/>
        </classes>
    </test>
    <test name="Safari Test">
        <parameter name="browser" value="safari"/>
        <classes>
            <class name="WebAutomationTest"/>
        </classes>
    </test>
</suite>
```

**Advantages**:
- `@DataProvider(parallel=true)` runs tests in parallel across browsers
- TestNG XML allows declarative parallelization
- Expected Conditions API is fluent
- ElementNotFoundException vs StaleElementReferenceException are well-documented

**Lines of Code**: ~50 for test + 15 for XML

### Rust Solution (Thirtyfour)

```rust
use thirtyfour::prelude::*;

#[tokio::test]
async fn test_login_chrome() {
    let caps = DesiredCapabilities::chrome();
    let driver = WebDriver::new("http://localhost:4444", caps).await.unwrap();
    
    driver.goto("https://example.com/login").await.unwrap();
    
    let email_field = driver.find(By::Id("email")).await.unwrap();
    let password_field = driver.find(By::Id("password")).await.unwrap();
    let submit_button = driver.find(By::Css("button[type='submit']")).await.unwrap();
    
    email_field.send_keys("alice@example.com").await.unwrap();
    password_field.send_keys("password123").await.unwrap();
    submit_button.click().await.unwrap();
    
    driver.wait(Duration::from_secs(10))
        .until(|_| async { driver.find(By::Id("dashboard")).await.is_ok() })
        .await
        .unwrap();
    
    let user_name = driver.find(By::Id("user-name")).await.unwrap().text().await.unwrap();
    assert_eq!(user_name, "Alice");
    
    driver.quit().await.unwrap();
}

#[tokio::test]
async fn test_login_firefox() {
    // Repeat the same test with Firefox driver...
}

#[tokio::test]
async fn test_login_safari() {
    // Repeat the same test with Safari driver...
}
```

**Disadvantages**:
- No parameterization (code duplication)
- No native XML-driven parallelization (manual test functions per browser)
- Await hell (async is verbose)
- No built-in Expected Conditions API

**Lines of Code**: ~100 (code duplication across 3 browser tests)

### Comparison

| Aspect | Java (Selenium + TestNG) | Rust (Thirtyfour) |
|--------|-------------------------|------------------|
| Test parameterization | ✅ `@DataProvider` | ❌ Manual functions per browser |
| Parallel execution | ✅ XML-driven `parallel="tests"` | ⚠️ Manual `#[tokio::test]` per browser |
| Expected Conditions | ✅ Rich fluent API | ❌ Manual wait loops |
| Code reuse | ✅ Single test runs N browsers | ❌ Duplicate test code per browser |
| Setup/teardown | ✅ One setup across all browsers | ❌ Per-test setup |
| Total LoC | ~65 | ~100 |
| Parallelization strategy | Declarative (XML) | Imperative (cargo test --test-threads) |

**Winner**: Java (TestNG's parameterization + XML parallelization is unmatched)

---

## Summary: Container Testing Ecosystem Maturity

### By Scenario

| Scenario | Java Advantage | Java LoC | Rust LoC | Ratio |
|----------|----------------|---------|---------|-------|
| PostgreSQL + Schema Init | `withInitScript()` | 40 | 80 | 1:2 |
| Kafka + Topic Pre-creation | `KAFKA_CREATE_TOPICS` env var | 60 | 90 | 1:1.5 |
| Multi-DB (3 databases) | `@Container` fields + DI | 40 | 120 | 1:3 |
| Docker Compose | Lifecycle automation | 55 | 50* | Even (but Rust is fragile) |
| HTTP Mocking | JSON-driven stubs | 80 | 25* | Even (but Rust is harder to maintain) |
| Browser Automation | Parameterization + XML | 65 | 100 | 1:1.5 |

**Key Insight**: Java wins where **declarative models** apply (database initialization, topic creation, container lifecycle). Rust matches or exceeds when tasks are **small and focused** (single HTTP mock, single test). But at scale (10+ HTTP stubs, multi-browser tests), Java's declarative edge grows.

### Ecosystem Maturity Ranking

1. **PostgreSQL** — 🏆 Java (init scripts, Spring Boot integration)
2. **Kafka** — 🏆 Java (KAFKA_CREATE_TOPICS, Spring Kafka)
3. **Multi-database** — 🏆 Java (DI + @Container)
4. **Docker Compose** — 🏆 Java (lifecycle automation)
5. **HTTP Mocking** — 🏆 Java (JSON-driven WireMock)
6. **Browser Automation** — 🏆 Java (TestNG parameterization + XML)

**Conclusion**: Java's Testcontainers ecosystem is 5-10 years ahead of Rust's testcontainers-rs in container-based testing maturity.
