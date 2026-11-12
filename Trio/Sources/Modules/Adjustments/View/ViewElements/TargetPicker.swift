import SwiftUI

struct TargetPicker: View {
    let label: String
    @Binding var selection: Decimal
    let options: [Decimal]
    let units: GlucoseUnits
    var hasChanges: Binding<Bool>?
    @Binding var targetStep: Decimal
    @Binding var displayPickerTarget: Bool
    var toggleScrollWheel: (_ picker: Bool) -> Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(
                (units == .mgdL ? selection.description : selection.formattedAsMmolL) + " " + units.rawValue
            )
            .foregroundColor(!displayPickerTarget ? .primary : .accentColor)
            .onTapGesture {
                displayPickerTarget = toggleScrollWheel(displayPickerTarget)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(
            (units == .mgdL ? selection.description : selection.formattedAsMmolL) + " " + units.spokenValue
        ))
        .accessibilityHint(Text(
            displayPickerTarget
                ? String(localized: "Closes the value picker", comment: "Accessibility hint")
                : String(localized: "Opens a picker to change the target", comment: "Accessibility hint")
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { displayPickerTarget = toggleScrollWheel(displayPickerTarget) }
        if displayPickerTarget {
            HStack {
                // Radio buttons and text on the left side
                VStack(alignment: .leading) {
                    // Radio buttons for step iteration
                    let stepChoices: [Decimal] = units == .mgdL ? [1, 5] : [1, 9]
                    ForEach(stepChoices, id: \.self) { step in
                        let label = (units == .mgdL ? step.description : step.formattedAsMmolL) + " " +
                            units.rawValue
                        RadioButton(
                            isSelected: targetStep == step,
                            label: label
                        ) {
                            targetStep = step
                            selection = Adjustments.StateModel.roundTargetToStep(selection, step)
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity)

                Spacer()

                // Picker on the right side
                Picker(selection: Binding(
                    get: { Adjustments.StateModel.roundTargetToStep(selection, targetStep) },
                    set: {
                        selection = $0
                        hasChanges?.wrappedValue = true // This safely updates if hasChanges is provided
                    }
                ), label: Text("")) {
                    ForEach(options, id: \.self) { option in
                        Text((units == .mgdL ? option.description : option.formattedAsMmolL) + " " + units.rawValue)
                            .tag(option)
                    }
                }
                .pickerStyle(WheelPickerStyle())
                .frame(maxWidth: .infinity)
            }
            .listRowSeparator(.hidden, edges: .top)
        }
    }
}

struct SmbHighBgTargetPicker: View {
    @Binding var selection: Decimal?
    let defaultTarget: Decimal
    let isGlobalEnabled: Bool
    let units: GlucoseUnits
    @Binding var displayPicker: Bool
    var toggleScrollWheel: (_ picker: Bool) -> Bool

    private func format(_ value: Decimal) -> String {
        (units == .mgdL ? value.description : value.formattedAsMmolL) + " " + units.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SMB With High Glucose")
                Spacer()
                Text(selection.map { format($0) } ?? String(localized: "Default"))
                    .foregroundColor(!displayPicker ? .primary : .accentColor)
                    .onTapGesture {
                        displayPicker = toggleScrollWheel(displayPicker)
                    }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("SMB With High Glucose"))
            .accessibilityValue(Text(
                selection.map { (units == .mgdL ? $0.description : $0.formattedAsMmolL) + " " + units.spokenValue }
                    ?? String(localized: "Default")
            ))
            .accessibilityHint(Text(
                displayPicker
                    ? String(localized: "Closes the value picker", comment: "Accessibility hint")
                    : String(localized: "Opens a picker to change the target", comment: "Accessibility hint")
            ))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { displayPicker = toggleScrollWheel(displayPicker) }
            Text(
                isGlobalEnabled
                    ?
                    String(
                        localized: "Starts SMBs from this glucose while the override runs. Default is \(format(defaultTarget)); higher values have no effect."
                    )
                    : String(localized: "Enable SMB With High Glucose is off, so this has no effect.")
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if displayPicker {
            Picker(selection: Binding(
                get: { selection ?? 0 },
                set: { selection = Override.validSmbHighBgTarget($0) }
            ), label: Text("")) {
                Text("Default").tag(Decimal(0))
                ForEach(Override.smbHighBgTargetOptions, id: \.self) { value in
                    Text(format(value)).tag(value)
                }
            }
            .pickerStyle(WheelPickerStyle())
            .listRowSeparator(.hidden, edges: .top)
        }
    }
}
