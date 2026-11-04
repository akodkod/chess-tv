import SwiftUI

struct PairingSheet: View {
  let session: MacSession
  @Environment(\.dismiss) private var dismiss
  @State private var submitted = false
  @State private var digits = Array(repeating: "", count: 6)
  private var code: String { digits.joined() }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Pair your TV").font(.headline)
      Text(session.pairing ? "Confirm the pairing request on your TV."
        : "Enter the six-digit code displayed in Chess TV.")
        .foregroundStyle(.secondary)
      if !session.pairing {
        PairingCodeInput(digits: $digits, onSubmit: submit)
          .frame(width: 304, height: 52)
      } else { ProgressView().controlSize(.small) }
      if let error = session.error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        if !session.pairing {
          Button("Pair") { submit() }
            .keyboardShortcut(.defaultAction)
            .disabled(code.count != 6 || submitted)
        }
      }
    }
    .padding(24).frame(width: 360)
    .onChange(of: session.paired) { _, paired in if paired { dismiss() } }
    .onChange(of: session.error) { _, _ in submitted = false }
    .onChange(of: session.pairing) { _, _ in submitted = false }
  }
  private func submit() {
    guard code.count == 6, !submitted else { return }
    submitted = true
    session.pair(code: code)
  }
}


private struct PairingCodeInput: NSViewRepresentable {
  @Binding var digits: [String]
  let onSubmit: () -> Void

  func makeNSView(context: Context) -> PairingCodeFields { PairingCodeFields() }

  func updateNSView(_ view: PairingCodeFields, context: Context) {
    view.onChange = { digits = $0 }
    view.onSubmit = onSubmit
    view.setDigits(digits)
  }
}

private final class PairingCodeFields: NSStackView, NSTextFieldDelegate {
  var onChange: ([String]) -> Void = { _ in }
  var onSubmit: () -> Void = {}
  private var fields: [NSTextField] = []
  private var boxes: [NSBox] = []
  private var activeIndex: Int?

  init() {
    super.init(frame: .zero)
    orientation = .horizontal
    spacing = 8
    for index in 0..<6 {
      let field = PairingDigitField(string: "")
      field.isBezeled = false
      field.isBordered = false
      field.drawsBackground = false
      field.focusRingType = .none
      field.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
      field.alignment = .center
      field.delegate = self
      field.setAccessibilityLabel("Pairing code digit \(index + 1) of 6")
      let box = NSBox()
      box.boxType = .custom
      box.titlePosition = .noTitle
      box.cornerRadius = 8
      box.contentViewMargins = .zero
      box.contentView?.addSubview(field)
      field.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        box.widthAnchor.constraint(equalToConstant: 44),
        box.heightAnchor.constraint(equalToConstant: 52),
        field.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        field.widthAnchor.constraint(equalToConstant: 40),
      ])
      fields.append(field)
      boxes.append(box)
      addArrangedSubview(box)
    }
    updateBorders()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in self?.focus(0) }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBorders()
  }

  func setDigits(_ digits: [String]) {
    for (index, value) in digits.enumerated() where fields[index].stringValue != value {
      fields[index].stringValue = value
    }
  }

  private func focus(_ index: Int) {
    fields[index].selectText(nil)
    activeIndex = index
    updateBorders()
  }

  private func updateBorders() {
    for (index, box) in boxes.enumerated() {
      box.fillColor = .textBackgroundColor
      box.borderColor = activeIndex == index ? .controlAccentColor : .separatorColor
      box.borderWidth = activeIndex == index ? 2 : 1
    }
  }

  func controlTextDidBeginEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    activeIndex = fields.firstIndex(of: field)
    updateBorders()
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    activeIndex = fields.firstIndex { $0.currentEditor() != nil }
    updateBorders()
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      let index = fields.firstIndex(of: field) else { return }
    let numbers = field.stringValue.filter { $0.isASCII && $0.isNumber }
    var next = index
    if numbers.count >= 6 {
      for (offset, digit) in numbers.prefix(6).enumerated() {
        fields[offset].stringValue = String(digit)
      }
      next = 5
    } else if !numbers.isEmpty {
      for (offset, digit) in numbers.prefix(6 - index).enumerated() {
        fields[index + offset].stringValue = String(digit)
      }
      next = min(5, index + numbers.count)
    } else {
      field.stringValue = ""
    }
    onChange(fields.map(\.stringValue))
    if !numbers.isEmpty { focus(next) }
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard let field = control as? NSTextField, let index = fields.firstIndex(of: field) else { return false }
    switch selector {
    case #selector(NSResponder.deleteBackward(_:)) where field.stringValue.isEmpty && index > 0:
      fields[index - 1].stringValue = ""
      onChange(fields.map(\.stringValue))
      focus(index - 1)
    case #selector(NSResponder.moveLeft(_:)):
      focus(max(0, index - 1))
    case #selector(NSResponder.moveRight(_:)):
      focus(min(5, index + 1))
    case #selector(NSResponder.insertNewline(_:)):
      onSubmit()
    default:
      return false
    }
    return true
  }
}

private final class PairingDigitField: NSTextField {
  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    selectText(nil)
  }
}
