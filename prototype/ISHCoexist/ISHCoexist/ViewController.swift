//  ViewController.swift
//  ISHCoexist — Stage 1 coexistence prototype
//
//  The whole test UI: one scrollable list, one card per stage 1 check,
//  with live pass/fail and the key output inline. No computer needed —
//  open the app on a real device and read the results here. The suite
//  starts automatically; the buttons below re-run it or drive the manual /
//  destructive actions. Test ④ and the relaunch check are manual by
//  design (see ISHTestHarness).
//
//  NOTE (build 12): this used to be a UITableView with automaticDimension
//  cells. Build 11 crashed ~0.4s after launch in UIKit's cell-height
//  measurement: UITableViewCell _viewConfigurationState ->
//  UIViewConfigurationState traitCollection, null deref (SIGSEGV, far=0),
//  reached via _heightForCell -> systemLayoutSizeFittingSize. The crash
//  happened on the first layout pass, on the main thread, while the
//  harness was running tests — iSH had already booted (PID 1 supervisor
//  parked) and Node was alive, so the crash is in UIKit's measurement
//  path, not in the guest. The table is replaced by a UIScrollView +
//  UIStackView of plain UIViews, which never goes through UITableView's
//  cell measurement / configuration-state machinery.

import UIKit

final class ResultCardView: UIView {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.masksToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        let top = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        top.axis = .horizontal
        top.spacing = 8
        top.alignment = .top
        let stack = UIStackView(arrangedSubviews: [top, detailLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with result: TestResult) {
        titleLabel.text = "\(result.id)  \(result.title)"
        statusLabel.text = result.status.rawValue
        switch result.status {
        case .pass: statusLabel.textColor = .systemGreen
        case .fail: statusLabel.textColor = .systemRed
        case .running: statusLabel.textColor = .systemOrange
        case .manual: statusLabel.textColor = .systemBlue
        case .na: statusLabel.textColor = .systemGray
        case .notRun: statusLabel.textColor = .tertiaryLabel
        }
        detailLabel.text = result.detail.isEmpty ? "—" : result.detail
    }
}

final class ViewController: UIViewController {
    private let harness = ISHTestHarness()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let summaryLabel = UILabel()
    private var cards: [String: ResultCardView] = [:]
    private var didAutoRun = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ISHCoexist · Stage 1"
        view.backgroundColor = .systemGroupedBackground

        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.numberOfLines = 0
        summaryLabel.text = "准备运行…"

        let runButton = UIButton(type: .system)
        runButton.setTitle("重新运行全部", for: .normal)
        runButton.addAction(UIAction { [weak self] _ in self?.harness.runAll() }, for: .touchUpInside)
        let stopButton = UIButton(type: .system)
        stopButton.setTitle("Stop Guest（只杀 pid ≥ 2）", for: .normal)
        stopButton.addAction(UIAction { [weak self] _ in
            ISHKernel.shared.stopGuest()
            self?.flashSummary("已发 stop：SIGTERM → SIGKILL（pid ≥ 2，PID 1 不受影响）")
        }, for: .touchUpInside)
        let resetButton = UIButton(type: .system)
        resetButton.setTitle("Reset rootfs（需重启 App）", for: .normal)
        resetButton.setTitleColor(.systemRed, for: .normal)
        resetButton.addAction(UIAction { [weak self] _ in self?.confirmReset() }, for: .touchUpInside)
        let crashButton = UIButton(type: .system)
        crashButton.setTitle("运行 ④ Node 真崩溃（App 将终止）", for: .normal)
        crashButton.setTitleColor(.systemRed, for: .normal)
        crashButton.addAction(UIAction { [weak self] _ in self?.confirmTrueCrash() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [summaryLabel, runButton, stopButton, resetButton, crashButton])
        header.axis = .vertical
        header.spacing = 8
        header.alignment = .leading

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
        ])

        contentStack.addArrangedSubview(header)

        // Build the fixed result list once (17 rows, order never changes);
        // refresh() only updates the cards in place, never rebuilds.
        var seenStages: [String] = []
        for r in harness.results {
            if !seenStages.contains(r.stage) {
                seenStages.append(r.stage)
                let sectionLabel = UILabel()
                sectionLabel.font = .preferredFont(forTextStyle: .footnote)
                sectionLabel.textColor = .secondaryLabel
                sectionLabel.text = r.stage
                contentStack.addArrangedSubview(sectionLabel)
            }
            let card = ResultCardView()
            card.configure(with: r)
            cards[r.id] = card
            contentStack.addArrangedSubview(card)
        }

        let footer = UILabel()
        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.numberOfLines = 0
        footer.text = "真机 only：iSH 库只有 arm64 device 切片，模拟器链接会失败。Guest 上限定稿值与 ② 的重测见 README（阶段 4 后）。"
        contentStack.addArrangedSubview(footer)

        refresh(results: harness.results)
        harness.onUpdate = { [weak self] results in
            self?.refresh(results: results)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didAutoRun {
            didAutoRun = true
            harness.runAll()
        }
    }

    private func refresh(results: [TestResult]) {
        let pass = results.filter { $0.status == .pass }.count
        let fail = results.filter { $0.status == .fail }.count
        let na = results.filter { $0.status == .na }.count
        let manual = results.filter { $0.status == .manual }.count
        let running = results.filter { $0.status == .running }.count
        summaryLabel.text = "通过 \(pass) · 失败 \(fail) · 不适用 \(na) · 手动 \(manual)"
            + (running > 0 ? " · 跑中 \(running)" : "")
            + "\nNode \(NodeRunner.shared.nodeVersion.isEmpty ? "未启动" : NodeRunner.shared.nodeVersion)"
            + " · iSH \(ISHKernel.shared.isBooted ? "已 boot" : "未 boot")"
        for r in results {
            cards[r.id]?.configure(with: r)
        }
    }

    private func flashSummary(_ text: String) {
        summaryLabel.text = text
    }

    private func confirmReset() {
        let alert = UIAlertController(
            title: "Reset rootfs？",
            message: "将停止 Guest、删除 rootfs、置位 didResetWhileBooted，之后终端拒绝起 shell，直到重启 App。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { _ in
            ISHKernel.shared.resetRootfsWhileBooted()
            self.flashSummary("已 Reset：重开 App 后 rootfs 会从 zip 重装")
        })
        present(alert, animated: true)
    }

    private func confirmTrueCrash() {
        let alert = UIAlertController(
            title: "运行测试 ④？",
            message: "Node 将向自己发 SIGSEGV。按 Node 默认路径，App 会终止（这是预期行为）。重开 App 后本页会显示观测结果。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "运行（App 将终止）", style: .destructive) { _ in
            self.harness.runTrueCrashTest()
        })
        present(alert, animated: true)
    }
}
