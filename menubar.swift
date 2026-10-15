import Cocoa

let LABEL   = "com.kkd.singbox"
let PLIST   = "/Library/LaunchDaemons/com.kkd.singbox.plist"
let HOME    = NSHomeDirectory()
let LOG     = HOME + "/.local/share/sing-box/sing-box.log"
let CONF    = HOME + "/.config/sing-box/config.json"
let API     = "http://127.0.0.1:9190"
let TESTURL = "https://www.gstatic.com/generate_204"
let KEY_SPEED = "showSpeed"

/// Команда через /bin/sh. Вывод читаем ДО waitUntilExit: иначе при ответе больше 64 КБ
/// (например /connections с сотней соединений) пайп переполняется, процесс виснет на записи,
/// мы — на ожидании, и опрос никогда не завершается.
@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let d = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func json(_ raw: String) -> [String: Any]? {
    guard let d = raw.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func isRunning() -> Bool {
    sh("/usr/bin/sudo -n /bin/launchctl print system/\(LABEL) >/dev/null 2>&1 && echo 1 || echo 0") == "1"
}

/// 1536 → «1,5 КБ»
func bytes(_ b: Int) -> String {
    let u = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
    var v = Double(b), i = 0
    while v >= 1024, i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v)) \(u[i])"
                  : String(format: v >= 100 ? "%.0f %@" : "%.1f %@", v, u[i])
}

func rate(_ bytesPerSec: Double) -> String { bytes(Int(bytesPerSec)) + "/с" }

struct Conn {
    var id: String
    var exit: String      // конечный выход: имя узла (node-1 / node-2) или direct
    var via: String       // группа правила, через которую пришли (selector/urltest), напр. «Авто»
    var host: String
    var proc: String
    var chain: String
    var up: Int
    var down: Int
    var viaProxy: Bool
}

struct State {
    var on = false
    var now = ""
    var all: [String] = []
    var delays: [String: Int] = [:]
    var upTotal = 0
    var downTotal = 0
    var upRate = 0.0
    var downRate = 0.0
    var conns: [Conn] = []
    var exits: [String] = []                       // туннели (узлы), в порядке конфига
    var routes: [(group: String, exit: String)] = []   // группа → куда она сейчас ведёт
    var exitRates: [String: (up: Double, down: Double)] = [:]
    var direct:  [Conn] { conns.filter { $0.exit == "direct" } }
}

/// Что происходит после клика «Включить/Выключить», пока launchctl не отработал
enum Pending { case none, turningOn, turningOff }

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()      // одно меню на всё время жизни: подмена item.menu под открытым меню оставляет кнопку «нажатой»
    var timer: Timer?
    var st = State()
    var pending = Pending.none
    var gen = 0, applied = 0, barrier = 0   // номера опросов: устаревшие ответы (старше применённого или начатые до переключения) выбрасываем
    // строки открытого меню, которые обновляем на месте при каждом опросе
    var liveToggle, liveStatus, liveNow, liveSession, liveConns, liveSpeed: NSMenuItem?
    var lastUp = 0, lastDown = 0
    var lastStamp = Date()
    var lastConn: [String: (up: Int, down: Int)] = [:]
    var showSpeed: Bool {
        get { UserDefaults.standard.bool(forKey: KEY_SPEED) }
        set { UserDefaults.standard.set(newValue, forKey: KEY_SPEED) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        render()
        tick()
        // .common — таймер тикает и пока меню открыто (в .default он замирает вместе с меню)
        let t = Timer(timeInterval: 2, repeats: true) { _ in self.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: сбор данных (в фоне, чтобы не морозить меню)

    func tick() {
        gen += 1
        let g = gen
        DispatchQueue.global(qos: .utility).async {
            var s = State()
            s.on = isRunning()
            if s.on {
                if let sel = json(sh("/usr/bin/curl -s --max-time 1 \(API)/proxies/proxy")),
                   let now = sel["now"] as? String {
                    s.now = now
                    s.all = (sel["all"] as? [String]) ?? []
                }
                if let root = json(sh("/usr/bin/curl -s --max-time 1 \(API)/proxies")),
                   let proxies = root["proxies"] as? [String: Any] {
                    let groups: Set<String> = ["Selector", "URLTest", "Fallback"]
                    func kind(_ n: String) -> String { ((proxies[n] as? [String: Any])?["type"] as? String) ?? "" }
                    for (name, v) in proxies {
                        if let node = v as? [String: Any],
                           let hist = node["history"] as? [[String: Any]],
                           let last = hist.last, let ms = last["delay"] as? Int, ms > 0 {
                            s.delays[name] = ms
                        }
                    }
                    let order = ((proxies["GLOBAL"] as? [String: Any])?["all"] as? [String]) ?? proxies.keys.sorted()
                    for name in order where name != "GLOBAL" {
                        let t = kind(name)
                        if groups.contains(t) {
                            var cur = name, hops = 0
                            while groups.contains(kind(cur)), hops < 5,
                                  let nx = (proxies[cur] as? [String: Any])?["now"] as? String { cur = nx; hops += 1 }
                            s.routes.append((name, cur))
                        } else if !t.isEmpty, t != "Direct" {
                            s.exits.append(name)
                        }
                    }
                }
                if let c = json(sh("/usr/bin/curl -s --max-time 1 \(API)/connections")) {
                    s.upTotal = (c["uploadTotal"] as? Int) ?? 0
                    s.downTotal = (c["downloadTotal"] as? Int) ?? 0
                    for raw in (c["connections"] as? [[String: Any]]) ?? [] {
                        let m = (raw["metadata"] as? [String: Any]) ?? [:]
                        let chains = (raw["chains"] as? [String]) ?? []
                        let host = (m["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            ?? (m["destinationIP"] as? String) ?? "?"
                        var proc = ((m["processPath"] as? String) ?? "")
                        if let slash = proc.lastIndex(of: "/") { proc = String(proc[proc.index(after: slash)...]) }
                        // у части соединений (UDP) цепочка — только имя группы: раскрываем её в текущий выход
                        var exit = chains.first ?? "direct"
                        var via = chains.count > 1 ? chains[1] : ""
                        if let r = s.routes.first(where: { $0.group == exit }) { via = exit; exit = r.exit }
                        s.conns.append(Conn(
                            id: (raw["id"] as? String) ?? "",
                            exit: exit,
                            via: via,
                            host: host,
                            proc: proc,
                            chain: chains.reversed().joined(separator: " → "),
                            up: (raw["upload"] as? Int) ?? 0,
                            down: (raw["download"] as? Int) ?? 0,
                            viaProxy: chains.contains { $0 != "direct" }))
                    }
                }
            }
            DispatchQueue.main.async {
                guard g > self.applied, g > self.barrier else { return }
                self.applied = g
                self.apply(s)
            }
        }
    }

    func apply(_ s: State) {
        var s = s
        let dt = max(0.5, Date().timeIntervalSince(lastStamp))
        if s.on, s.upTotal >= lastUp, s.downTotal >= lastDown, lastUp + lastDown > 0 {
            s.upRate = Double(s.upTotal - lastUp) / dt
            s.downRate = Double(s.downTotal - lastDown) / dt
        }
        // скорость по каждому выходу — по приросту счётчиков соединений между опросами
        var seen: [String: (up: Int, down: Int)] = [:]
        for c in s.conns {
            seen[c.id] = (c.up, c.down)
            guard let old = lastConn[c.id], c.up >= old.up, c.down >= old.down else { continue }
            var r = s.exitRates[c.exit] ?? (0, 0)
            r.up += Double(c.up - old.up) / dt; r.down += Double(c.down - old.down) / dt
            s.exitRates[c.exit] = r
        }
        lastConn = seen
        lastUp = s.upTotal; lastDown = s.downTotal; lastStamp = Date()
        st = s
        render()
    }

    // MARK: строка меню

    func icon() -> NSImage? {
        let name: String, color: NSColor
        switch pending {
        case .none:
            name = st.on ? "checkmark.shield.fill" : "xmark.shield.fill"
            color = st.on ? .systemGreen : .systemGray
        default:
            name = "shield.lefthalf.filled"; color = .systemOrange   // переключаемся
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let out = img.withSymbolConfiguration(cfg); out?.isTemplate = false
        return out
    }

    func render() {
        item.button?.image = icon()
        item.button?.imagePosition = (showSpeed && st.on) ? .imageLeading : .imageOnly

        if showSpeed && st.on {
            item.length = NSStatusItem.variableLength
            let para = NSMutableParagraphStyle()
            para.alignment = .right
            para.lineSpacing = -3
            let text = "↑ \(rate(st.upRate))\n↓ \(rate(st.downRate))"
            item.button?.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .paragraphStyle: para,
                .foregroundColor: NSColor.labelColor,
            ])
        } else {
            item.length = NSStatusItem.squareLength
            item.button?.title = ""
        }
        item.button?.toolTip = st.on ? "sing-box: \(st.now)" : "sing-box выключен"
        // меню не перестраиваем (оно собирается при открытии), только освежаем живые строки
        if let t = liveToggle { fillToggle(t) }
        liveStatus?.title = statusLine()
        liveNow?.title = nowLine()
        liveSession?.title = sessionLine()
        liveConns?.title = connsLine()
        liveSpeed?.state = showSpeed ? .on : .off
    }

    // MARK: меню

    func info(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    func act(_ title: String, _ sel: Selector, on state: Bool? = nil, obj: Any? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        mi.representedObject = obj
        if let s = state { mi.state = s ? .on : .off }
        return mi
    }

    // Меню собирается заново при каждом открытии (NSMenuDelegate), а не при каждом опросе:
    // замена item.menu под открытым меню — та самая «залипшая» кнопка.
    func menuNeedsUpdate(_ m: NSMenu) { rebuild() }
    func menuWillOpen(_ m: NSMenu) { tick() }

    func statusLine() -> String {
        if let ms = st.delays[st.now] { return "Работает · \(st.now) · \(ms) мс" }
        return "Работает · \(st.now)"
    }
    func nowLine() -> String { "Сейчас:     ↑ \(rate(st.upRate))   ↓ \(rate(st.downRate))" }
    func sessionLine() -> String { "За сессию:  ↑ \(bytes(st.upTotal))   ↓ \(bytes(st.downTotal))" }
    func connsLine() -> String {
        let d = st.direct.count
        return "Соединений: \(st.conns.count) · в туннелях \(st.conns.count - d) · напрямую \(d)"
    }

    /// Верхний пункт: «Выключить»/«Включить», а пока launchctl работает — «Выключаю…» без действия
    func fillToggle(_ mi: NSMenuItem) {
        switch pending {
        case .turningOn:  mi.title = "Включаю…";  mi.action = nil; mi.isEnabled = false
        case .turningOff: mi.title = "Выключаю…"; mi.action = nil; mi.isEnabled = false
        case .none:
            mi.title = st.on ? "Выключить" : "Включить"
            mi.action = #selector(toggle); mi.target = self; mi.isEnabled = true
        }
    }

    func rebuild() {
        menu.removeAllItems()
        liveStatus = nil; liveNow = nil; liveSession = nil; liveConns = nil; liveSpeed = nil

        // включить/выключить — всегда первым пунктом, отдельно от остального
        let t = NSMenuItem(); fillToggle(t)
        liveToggle = t
        menu.addItem(t)
        menu.addItem(.separator())

        guard st.on else {
            menu.addItem(info("Выключен — весь трафик напрямую"))
            menu.addItem(.separator())
            menu.addItem(act("Открыть конфиг", #selector(openConf)))
            menu.addItem(act("Показать лог", #selector(openLog)))
            menu.addItem(.separator())
            menu.addItem(act("Выйти из индикатора", #selector(quit)))
            return
        }

        // состояние
        liveStatus = info(statusLine());   menu.addItem(liveStatus!)
        liveNow = info(nowLine());         menu.addItem(liveNow!)
        liveSession = info(sessionLine()); menu.addItem(liveSession!)
        liveConns = info(connsLine());     menu.addItem(liveConns!)
        menu.addItem(.separator())

        // что в какой туннель уходит / что мимо
        let d = st.direct
        var names = st.exits
        for c in st.conns where c.exit != "direct" && !names.contains(c.exit) { names.append(c.exit) }
        for name in names {
            let cs = st.conns.filter { $0.exit == name }
            menu.addItem(sub(exitTitle(name, cs.count), cs, empty: "Сейчас через \(name) ничего не идёт"))
        }
        menu.addItem(sub(exitTitle("Напрямую", d.count, key: "direct"), d, empty: "Нет прямых соединений"))
        menu.addItem(.separator())

        // какая группа правил куда сейчас ведёт
        if !st.routes.isEmpty {
            menu.addItem(info("Правила → выход"))
            for r in st.routes { menu.addItem(info("   \(r.group) → \(r.exit)")) }
            menu.addItem(.separator())
        }

        // сервер
        menu.addItem(info("Сервер"))
        for name in st.all {
            let label: String
            if name == "Авто" { label = "   Авто — самый быстрый" }
            else if let ms = st.delays[name] { label = "   \(name) — \(ms) мс" }
            else { label = "   \(name) — нет замера" }
            menu.addItem(act(label, #selector(pick(_:)), on: name == st.now, obj: name))
        }
        menu.addItem(act("Перепроверить задержки", #selector(recheck)))
        menu.addItem(.separator())

        liveSpeed = act("Показывать скорость в меню-баре", #selector(toggleSpeed), on: showSpeed)
        menu.addItem(liveSpeed!)
        menu.addItem(act("Открыть конфиг", #selector(openConf)))
        menu.addItem(act("Показать лог", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(act("Выйти из индикатора", #selector(quit)))
    }

    /// «node-1 · 240 мс — 12   ↓ 300 КБ/с ↑ 10 КБ/с»
    func exitTitle(_ name: String, _ n: Int, key: String? = nil) -> String {
        var t = name
        if let ms = st.delays[name] { t += " · \(ms) мс" }
        t += " — \(n)"
        if let r = st.exitRates[key ?? name], r.up + r.down >= 1024 {
            t += "   ↓ \(rate(r.down)) ↑ \(rate(r.up))"
        }
        return t
    }

    /// Подменю со списком «хост — процесс — объём», самые жирные сверху
    func sub(_ title: String, _ conns: [Conn], empty: String) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sm = NSMenu()
        if conns.isEmpty {
            sm.addItem(info(empty))
        } else {
            // схлопываем по паре «хост + процесс», чтобы не было двадцати строк одного и того же
            // внутри выхода — по группе правила, если их несколько
            var vias: [String] = []
            for c in conns where !vias.contains(c.via) { vias.append(c.via) }
            vias.sort { a, b in
                conns.filter { $0.via == a }.reduce(0) { $0 + $1.up + $1.down } >
                conns.filter { $0.via == b }.reduce(0) { $0 + $1.up + $1.down }
            }
            let limit = max(8, 25 / vias.count)
            for via in vias {
                let part = conns.filter { $0.via == via }
                if vias.count > 1 {
                    if sm.items.count > 0 { sm.addItem(.separator()) }
                    sm.addItem(info("по правилу «\(via.isEmpty ? "прямое" : via)» — \(part.count)"))
                }
                var agg: [String: (host: String, proc: String, up: Int, down: Int, n: Int)] = [:]
                for c in part {
                    let key = c.host + "|" + c.proc
                    var e = agg[key] ?? (c.host, c.proc, 0, 0, 0)
                    e.up += c.up; e.down += c.down; e.n += 1
                    agg[key] = e
                }
                for e in agg.values.sorted(by: { $0.down + $0.up > $1.down + $1.up }).prefix(limit) {
                    let who = e.proc.isEmpty ? "—" : e.proc
                    let cnt = e.n > 1 ? " ×\(e.n)" : ""
                    sm.addItem(info("\(e.host)\(cnt)  ·  \(who)  ·  ↑ \(bytes(e.up)) ↓ \(bytes(e.down))"))
                }
                if agg.count > limit { sm.addItem(info("…ещё \(agg.count - limit)")) }
            }
        }
        parent.submenu = sm
        return parent
    }

    // MARK: действия

    @objc func toggleSpeed() { showSpeed.toggle(); render() }

    @objc func pick(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let body = try? JSONSerialization.data(withJSONObject: ["name": name]),
              let js = String(data: body, encoding: .utf8) else { return }
        let esc = js.replacingOccurrences(of: "'", with: "'\\''")
        DispatchQueue.global().async {
            sh("/usr/bin/curl -s --max-time 3 -X PUT -H 'Content-Type: application/json' -d '\(esc)' \(API)/proxies/proxy")
            DispatchQueue.main.async { self.tick() }
        }
    }

    @objc func recheck() {
        let all = st.all
        DispatchQueue.global().async {
            for name in all where name != "Авто" {
                let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                sh("/usr/bin/curl -s --max-time 8 '\(API)/proxies/\(enc)/delay?url=\(TESTURL)&timeout=5000'")
            }
            DispatchQueue.main.async { self.tick() }
        }
    }

    @objc func toggle() {
        guard pending == .none else { return }      // второй клик, пока первый не отработал
        let turnOn = !st.on
        pending = turnOn ? .turningOn : .turningOff
        render()                                    // иконка и верхний пункт — сразу, не ждём опроса
        DispatchQueue.global().async {
            // bootout возвращается, когда демон уже вышел (~1 с)
            sh(turnOn ? "/usr/bin/sudo -n /bin/launchctl bootstrap system \(PLIST)"
                      : "/usr/bin/sudo -n /bin/launchctl bootout system/\(LABEL)")
            DispatchQueue.main.async {
                self.pending = .none
                self.barrier = self.gen             // опросы, начатые во время переключения, уже неверны
                self.tick()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.tick() }   // Clash API поднимается чуть позже демона
            }
        }
    }

    @objc func openConf() { DispatchQueue.global().async { sh("/usr/bin/open -t '\(CONF)'") } }
    @objc func openLog()  { DispatchQueue.global().async { sh("/usr/bin/open -a Console '\(LOG)' 2>/dev/null || /usr/bin/open -t '\(LOG)'") } }
    @objc func quit()     { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
