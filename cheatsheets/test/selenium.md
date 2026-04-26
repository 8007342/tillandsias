# Selenium WebDriver

@trace spec:agent-cheatsheets

**Version baseline**: Selenium 4.x (install per-project; not in forge image).
**Use when**: cross-browser end-to-end web testing with broad language SDK support (Python, Java, JS/TS, C#, Ruby). Compare with Playwright (newer, single-vendor, simpler bring-up).

## Provenance

- Selenium official documentation (selenium.dev): <https://www.selenium.dev/documentation/webdriver/> — WebDriver API, locators, waits, browsers
- Selenium WebDriver W3C specification: <https://w3c.github.io/webdriver/> — the underlying W3C Recommendation standard
- Selenium Manager documentation: <https://www.selenium.dev/documentation/selenium_manager/> — automatic driver resolution (introduced in Selenium 4.6)
- **Last updated:** 2026-04-25

Verified: `WebDriverWait` with `ExpectedConditions` confirmed in official docs (Waiting with Expected Conditions section); `By.CSS_SELECTOR` confirmed in locators section; Selenium Manager auto-resolution confirmed (introduced as beta in 4.6, stable in later 4.x); `--headless=new` Chrome flag and `/dev/shm` container issues documented in the Chrome-specific section.

## Quick reference

| Language | Install | Driver bring-up |
|---|---|---|
| Python | `pip install selenium` | `driver = webdriver.Chrome()` (Selenium Manager auto-resolves driver) |
| Java | `org.seleniumhq.selenium:selenium-java:4.x` (Maven/Gradle) | `WebDriver driver = new ChromeDriver();` |
| JS/TS | `npm i selenium-webdriver` | `const driver = await new Builder().forBrowser('chrome').build();` |

| Locator (Python `By.*`) | When to use |
|---|---|
| `By.ID` | Unique, stable element id — fastest, most reliable |
| `By.CSS_SELECTOR` | Default for everything else; readable, fast |
| `By.XPATH` | Last resort: traverse parents, match by text content |
| `By.NAME`, `By.CLASS_NAME`, `By.TAG_NAME` | Niche; prefer CSS |
| `By.LINK_TEXT`, `By.PARTIAL_LINK_TEXT` | `<a>` matched by visible text |

| Wait strategy | Effect |
|---|---|
| `WebDriverWait(driver, 10).until(EC.<cond>)` | Explicit — poll until condition true or timeout. **Preferred.** |
| `driver.implicitly_wait(10)` | Implicit — applied to every `find_element`. Combine with explicit and behaviour goes weird. |
| `time.sleep(N)` | Anti-pattern. Use it only to debug a flake, never to fix one. |

## Common patterns

### Pattern 1 — Explicit wait + ExpectedConditions

```python
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By

el = WebDriverWait(driver, 10).until(
    EC.element_to_be_clickable((By.CSS_SELECTOR, "button#submit"))
)
el.click()
```

`EC.*` covers presence, visibility, clickability, text-to-be-present, alert-is-present, frame-available-and-switch.

### Pattern 2 — Page Object Model

```python
class LoginPage:
    def __init__(self, driver): self.driver = driver
    def login(self, user, pw):
        self.driver.find_element(By.ID, "user").send_keys(user)
        self.driver.find_element(By.ID, "pw").send_keys(pw)
        self.driver.find_element(By.ID, "submit").click()
        return DashboardPage(self.driver)
```

Centralises selectors and flow; tests assert on returned page objects.

### Pattern 3 — Headless browser

```python
from selenium.webdriver.chrome.options import Options
opts = Options()
opts.add_argument("--headless=new")
opts.add_argument("--no-sandbox")          # required in unprivileged containers
opts.add_argument("--disable-dev-shm-usage")  # /dev/shm is tiny inside containers
driver = webdriver.Chrome(options=opts)
```

### Pattern 4 — Selenium Grid for parallel runs

```bash
# Hub + nodes (typically separate containers)
java -jar selenium-server.jar hub
java -jar selenium-server.jar node --hub http://hub:4444

# Test connects to remote
driver = webdriver.Remote(
    command_executor="http://hub:4444/wd/hub",
    options=opts,
)
```

### Pattern 5 — Screenshot + page source on failure

```python
import pytest
@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    rep = outcome.get_result()
    if rep.when == "call" and rep.failed:
        drv = item.funcargs.get("driver")
        if drv:
            drv.save_screenshot(f"failure-{item.name}.png")
            (Path("failure-" + item.name + ".html")).write_text(drv.page_source)
```

## Common pitfalls

- **Mixing implicit and explicit waits** — implicit wait applies to every `find_element`; explicit wait polls inside `until`. When both are set, the implicit timeout multiplies inside the explicit poll, producing wait times like 30s instead of 10s. Pick one — the WebDriver project recommends explicit-only.
- **Stale element references** — capture an element, the page re-renders (SPA, AJAX), then call `.click()` → `StaleElementReferenceException`. Re-find immediately before interacting, or wrap calls in a retry helper. Page Object Model methods should re-locate, not cache.
- **WebDriver / browser version mismatch** — Selenium 4.6+ ships **Selenium Manager** which resolves drivers automatically; on older 4.x or pinned drivers, a Chrome auto-update breaks every test until `chromedriver` matches. Either upgrade Selenium to use the manager, or pin browser + driver together.
- **`<iframe>` content invisible until you switch** — `driver.find_element` only sees the current frame. Use `driver.switch_to.frame(el)` before searching, `driver.switch_to.default_content()` to come back. A common symptom is `NoSuchElementException` on an element you can plainly see in DevTools.
- **JS-rendered content + `time.sleep`** — sleeping for "long enough" is the #1 source of flakes. Always wait on a *condition* (`EC.text_to_be_present_in_element`, `EC.visibility_of_element_located`) — never on a duration.
- **`headless=old` vs `headless=new`** — Chrome 109+ introduced a new headless mode (`--headless=new`) that matches the headed renderer. The legacy `--headless` flag still works but renders subtly differently (different fonts, no GPU). Tests that pass headed and fail headless are usually hitting this.
- **`/dev/shm` exhaustion in containers** — Chrome stores tab IPC there; the default container `/dev/shm` is 64 MB. Crash with `DevToolsActivePort file doesn't exist` or `tab crashed`. Add `--disable-dev-shm-usage` (Chrome falls back to `/tmp`) or mount a larger tmpfs.
- **Implicit waits don't apply to `WebDriverWait` conditions you wrote yourself** — only to `find_element*` calls. A custom lambda condition (`lambda d: d.execute_script(...)`) gets no implicit wait magic.

## Forge-specific

Selenium needs a **browser binary** AND a **matching driver**. The forge does not ship Chrome or Firefox by default — they are bulky (Chrome ~400 MB installed, plus driver) and pull in proprietary or partly-proprietary stacks that the minimal Fedora forge image avoids.

Three options inside the forge:

- **Per-project install** (heavyweight) — pull `google-chrome-stable` or `firefox` into the project's working tree and let Selenium Manager fetch the driver. You pay disk + RAM on every container start, and the binary is lost on stop.
- **Sidecar browser container** (recommended) — run `selenium/standalone-chrome` (or `-firefox`) as a separate container in the enclave; point tests at it via `webdriver.Remote(command_executor="http://selenium:4444/wd/hub", ...)`. The forge stays clean; the browser image is cached by podman.
- **Switch to Playwright** — `npx playwright install` fetches matched Chromium/Firefox/WebKit per project on demand; no driver-mismatch class of bug. See `test/playwright.md`.

If browser deps genuinely need to ship in the forge image, write a `RUNTIME_LIMITATIONS_NNN.md` per `runtime/runtime-limitations.md` — that's the channel for promoting a missing-tool report into an image change.

## See also

- `test/playwright.md` — modern alternative; auto-installs browsers, single-vendor, fewer footguns
- `runtime/runtime-limitations.md` — how to request browser additions to the forge image
- `runtime/forge-container.md` — why the forge ships minimal and what's mutable
