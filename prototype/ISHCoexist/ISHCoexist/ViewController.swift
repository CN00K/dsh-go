//  ViewController.swift
//  ISHCoexist — Stage 1 coexistence prototype
//
//  The whole test UI: one grouped table, one row per stage 1 check, with
//  live pass/fail and the key output inline. No computer needed — open
//  the app on a real device and read the results here. The suite starts
//  automatically; the buttons below re-run it or drive the manual /
//  destructive actions. Test ④ and the relaunch check are manual by
//  design (see ISHTestHarness).

import UIKit

final class ResultCell: UITableViewCell {
    static let reuseId = "ResultCell"

    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
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
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
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

final class ViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let harness = ISHTestHarness()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let summaryLabel = UILabel()
    private var grouped: [(stage: String, rows: [TestResult])] = []
    private var didAutoRun = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ISHCoexist · Stage 1"
        view.backgroundColor = .systemBackground

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
        header.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        header.isLayoutMarginsRelativeArrangement = true
        tableView.tableHeaderView = header
        // Size the header to its content at the table's width, so the
        // multi-line summary label wraps instead of clipping.
        let targetWidth = view.bounds.width
        header.frame = CGRect(x: 0, y: 0, width: targetWidth,
                              height: header.systemLayoutSizeFitting(
                                  CGSize(width: targetWidth,
                                         height: UIView.layoutFittingCompressedSize.height)).height)
        tableView.tableHeaderView = header

        let footer = UILabel()
        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.numberOfLines = 0
        footer.text = "真机 only：iSH 库只有 arm64 device 切片，模拟器链接会失败。Guest 上限定稿值与 ② 的重测见 README（阶段 4 后）。"
        footer.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 60)
        tableView.tableFooterView = footer

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ResultCell.self, forCellReuseIdentifier: ResultCell.reuseId)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 90
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

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
        var order: [String] = []
        var map: [String: [TestResult]] = [:]
        for r in results {
            if map[r.stage] == nil { order.append(r.stage) }
            map[r.stage, default: []].append(r)
        }
        grouped = order.map { (stage: $0, rows: map[$0] ?? []) }
        let pass = results.filter { $0.status == .pass }.count
        let fail = results.filter { $0.status == .fail }.count
        let na = results.filter { $0.status == .na }.count
        let manual = results.filter { $0.status == .manual }.count
        let running = results.filter { $0.status == .running }.count
        summaryLabel.text = "通过 \(pass) · 失败 \(fail) · 不适用 \(na) · 手动 \(manual)"
            + (running > 0 ? " · 跑中 \(running)" : "")
            + "\nNode \(NodeRunner.shared.nodeVersion.isEmpty ? "未启动" : NodeRunner.shared.nodeVersion)"
            + " · iSH \(ISHKernel.shared.isBooted ? "已 boot" : "未 boot")"
        tableView.reloadData()
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

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int { grouped.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        grouped[section].stage
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        grouped[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ResultCell.reuseId,
                                                 for: indexPath) as! ResultCell
        cell.configure(with: grouped[indexPath.section].rows[indexPath.row])
        return cell
    }
}
