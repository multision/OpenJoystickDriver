#if canImport(SwiftUI)

  import AppKit
  import Foundation
  import OpenJoystickDriverKit
  import SwiftUI

  // MARK: - Profile editor

  struct ProfileEditorView: View {
    let profile: RemappingProfile
    @ObservedObject
    var editor: ProfileEditorViewModel
    @ObservedObject
    var viewModel: RuntimeViewModel
    let isActive: Bool
    let isEditingBlocked: Bool
    @Binding
    var selectedSection: ProfileEditorSection
    let onDelete: () -> Void
    let onExport: (RemappingProfile) -> Void
    let onEditingStateChanged: (Bool) -> Void
    let onMutationStarted: (RuntimeMutationRequest) -> Bool
    let onMutationResult: (RuntimeMutationResult) -> Void

    var draft: RuntimeProfileDraft {
      get { editor.draft }
      nonmutating set { editor.draft = newValue }
    }
    var expectedCurrent: RemappingProfile {
      get { editor.expectedCurrent }
      nonmutating set { editor.expectedCurrent = newValue }
    }
    var activeSheet: ProfileEditorSheet? {
      get { editor.activeSheet }
      nonmutating set { editor.activeSheet = newValue }
    }
    var showingConflict: Bool {
      get { editor.showingConflict }
      nonmutating set { editor.showingConflict = newValue }
    }
    var localError: String? {
      get { editor.localError }
      nonmutating set { editor.localError = newValue }
    }
    var saveError: String? {
      get { editor.saveError }
      nonmutating set { editor.saveError = newValue }
    }
    var saveState: ProfileEditorSaveState {
      get { editor.saveState }
      nonmutating set { editor.saveState = newValue }
    }

    init(
      profile: RemappingProfile,
      editor: ProfileEditorViewModel,
      viewModel: RuntimeViewModel,
      isActive: Bool,
      isEditingBlocked: Bool,
      selectedSection: Binding<ProfileEditorSection>,
      onDelete: @escaping () -> Void,
      onExport: @escaping (RemappingProfile) -> Void,
      onEditingStateChanged: @escaping (Bool) -> Void,
      onMutationStarted: @escaping (RuntimeMutationRequest) -> Bool,
      onMutationResult: @escaping (RuntimeMutationResult) -> Void
    ) {
      self.profile = profile
      self.editor = editor
      self.viewModel = viewModel
      self.isActive = isActive
      self.isEditingBlocked = isEditingBlocked
      _selectedSection = selectedSection
      self.onDelete = onDelete
      self.onExport = onExport
      self.onEditingStateChanged = onEditingStateChanged
      self.onMutationStarted = onMutationStarted
      self.onMutationResult = onMutationResult
    }

    var body: some View {
      GeometryReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
          editorHeader(width: proxy.size.width)
          Divider()
          sectionNavigation(width: proxy.size.width)
          Divider()
          editorContent(width: proxy.size.width)
          Divider()
          editorFooter
        }
      }.disabled(isEditingDisabled).sheet(item: $editor.activeSheet) { sheet in
        Group {
          switch sheet {
          case .metadata: ProfileMetadataSheet(profile: draft.profile) { updateMetadata($0) }
          case .sticks:
            ProfileStickSheet(mappings: draft.profile.stickMappings) { mappings in
              draft = try draft.settingStickMappings(mappings)
              localError = nil
              saveError = nil
              reportEditingState()
            }
          case .triggers:
            ProfileTriggerSheet(mappings: draft.profile.triggerMappings) { mappings in
              draft = try draft.settingTriggerMappings(mappings)
              localError = nil
              saveError = nil
              reportEditingState()
            }
          case .touch:
            ProfileTouchSheet(mappings: draft.profile.touchMappings) { mappings in
              applyDraftChange { try draft.settingTouchMappings(mappings) }
            }
          case .motion:
            ProfileMotionSheet(tuning: draft.profile.motionTuning, output: draft.profile.gyroOutput)
            { tuning, output in
              applyDraftChange { try draft.settingMotionTuning(tuning, gyroOutput: output) }
            }
          case .layerMotion(let layer):
            ProfileMotionSheet(
              tuning: layer.motionTuning ?? draft.profile.motionTuning,
              output: .default,
              showsGyroOutput: false,
              onInherit: {
                applyDraftChange { try draft.settingLayerMotionTuning(nil, for: layer.id) }
              },
              onSave: { tuning, _ in
                applyDraftChange { try draft.settingLayerMotionTuning(tuning, for: layer.id) }
              }
            )
          case .capture:
            CaptureAssignmentSheet(viewModel: viewModel) { source, destination in
              addBinding(source: source, destination: destination)
            }
          case .adjustment(let binding):
            AxisAdjustmentSheet(binding: binding) { tuning in
              updateAxisTuning(tuning, for: binding.id)
            }
          case .behavior(let binding):
            BindingBehaviorSheet(binding: binding) {
              behavior,
              pulseDurationMs,
              turbo,
              longHold,
              doubleTap,
              actions in
              applyDraftChange {
                try draft.settingBindingBehaviors(
                  behavior: behavior,
                  pulseDurationMs: pulseDurationMs,
                  turbo: turbo,
                  longHold: longHold,
                  doubleTap: doubleTap,
                  for: binding.id
                ).settingAdditionalActions(actions, for: binding.id)
              }
            }
          case .chord:
            ProfileCombinationSheet(kind: .chord) { sources, mode, windowMs, destination in
              addChord(sources: sources, mode: mode, windowMs: windowMs, destination: destination)
            }
          case .sequence:
            ProfileCombinationSheet(kind: .sequence) { sources, _, windowMs, destination in
              addSequence(sources: sources, windowMs: windowMs, destination: destination)
            }
          case .layer:
            ProfileLayerSheet { name, activator, mode in
              addLayer(name: name, activator: activator, mode: mode)
            }
          case .layerBinding(let layer):
            ProfileLayerBindingSheet(layer: layer) { source, destination in
              setLayerBinding(layerID: layer.id, source: source, destination: destination)
            }
          case .layerAdjustment(let layerID, let binding):
            AxisAdjustmentSheet(binding: binding) { tuning in
              updateLayerAxisTuning(tuning, layerID: layerID, bindingID: binding.id)
            }
          case .layerBehavior(let layerID, let binding):
            BindingBehaviorSheet(binding: binding) {
              behavior,
              pulseDurationMs,
              turbo,
              longHold,
              doubleTap,
              actions in
              applyDraftChange {
                try draft.settingLayerBindingBehaviors(
                  behavior: behavior,
                  pulseDurationMs: pulseDurationMs,
                  layerID: layerID,
                  bindingID: binding.id,
                  turbo: turbo,
                  longHold: longHold,
                  doubleTap: doubleTap
                ).settingAdditionalActions(actions, for: binding.id, layerID: layerID)
              }
            }
          }
        }.disabled(isEditingDisabled)
      }.onReceive(viewModel.$mutationState) { mutation in handleMutation(mutation) }.onAppear {
        reportEditingState()
      }
    }

    func editorHeader(width: CGFloat) -> some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 10) {
          TextField(
            OJDLocalized.string("common.profileName", fallback: "Profile name"),
            text: nameBinding
          ).font(.headline.weight(.semibold)).textFieldStyle(PlainTextFieldStyle()).frame(
            maxWidth: .infinity,
            alignment: .leading
          ).ojdAccessibilityLabel(
            OJDLocalized.string("common.profileName", fallback: "Profile name")
          )
          primaryActivationAction
          profileActionMenu
        }
        if width < ProfilePresentationPolicy.compactNavigationWidth {
          VStack(alignment: .leading, spacing: 4) { profileFacts }
        } else {
          HStack(spacing: 10) { profileFacts }
        }
        if showingConflict {
          ConflictBanner(
            reload: {
              showingConflict = false
              Task { @MainActor in
                await viewModel.refresh()
                if case .available(let snapshot) = viewModel.remappingState,
                  let latest = snapshot.profiles.first(where: { $0.id == profile.id })
                {
                  expectedCurrent = latest
                  draft = RuntimeProfileDraft(profile: latest)
                  saveError = nil
                  reportEditingState()
                }
              }
            },
            keepEditing: { showingConflict = false }
          )
        }
      }.padding(.horizontal, 28).padding(.vertical, 18)
    }

    @ViewBuilder
    var profileFacts: some View {
      Text(RuntimePresentation.profileScopeLabel(draft.profile.applicationScope)).foregroundColor(
        Color(NSColor.secondaryLabelColor)
      )
      Text(assignmentCountLabel(draft.profile.bindings.count)).foregroundColor(
        Color(NSColor.secondaryLabelColor)
      )
      Text(activationLabel).foregroundColor(Color(NSColor.secondaryLabelColor))
      saveStatusView
    }

    @ViewBuilder
    var primaryActivationAction: some View {
      if profile.joyConPair == nil {
        Button(
          OJDLocalized.string(
            isActive ? "common.deactivate" : "common.setActive",
            fallback: isActive ? "Deactivate" : "Set active"
          )
        ) { isActive ? deactivateProfile() : activateProfile() }.disabled(isMutationActive)
      }
    }

    var profileActionMenu: some View {
      Picker(
        OJDLocalized.string("profiles.actions", fallback: "Profile actions"),
        selection: Binding<ProfileEditorMenuAction?>(
          get: { nil },
          set: { action in if let action { performMenuAction(action) } }
        )
      ) {
        Text(OJDLocalized.string("profiles.actions", fallback: "Profile actions")).tag(
          Optional<ProfileEditorMenuAction>.none
        )
        ForEach(menuActions, id: \.self) { action in Text(action.title).tag(Optional(action)) }
      }.pickerStyle(PopUpButtonPickerStyle()).labelsHidden().frame(width: 132)
        .ojdAccessibilityLabel(OJDLocalized.string("profiles.actions", fallback: "Profile actions"))
        .disabled(isMutationActive)
    }

    func sectionNavigation(width: CGFloat) -> some View {
      Group {
        if ProfilePresentationPolicy.navigationStyle(for: width) == .segmented {
          Picker(
            OJDLocalized.string("profiles.editorSection", fallback: "Profile editor section"),
            selection: $selectedSection
          ) {
            ForEach(ProfilePresentationPolicy.sectionOrder) { section in
              Text(section.title).tag(section)
            }
          }.pickerStyle(SegmentedPickerStyle()).labelsHidden()
        } else {
          HStack {
            Text(OJDLocalized.string("profiles.editorSection", fallback: "Section"))
              .foregroundColor(Color(NSColor.secondaryLabelColor))
            Picker("", selection: $selectedSection) {
              ForEach(ProfilePresentationPolicy.sectionOrder) { section in
                Text(section.title).tag(section)
              }
            }.labelsHidden().pickerStyle(PopUpButtonPickerStyle()).frame(maxWidth: .infinity)
          }
        }
      }.padding(.horizontal, 28).padding(.vertical, 10).ojdAccessibilityLabel(
        OJDLocalized.string("profiles.editorSection", fallback: "Profile editor section")
      ).ojdAccessibilityValue(selectedSection.title)
    }

    func editorContent(width: CGFloat) -> some View {
      ScrollView {
        sectionContent(assignmentLayout: ProfilePresentationPolicy.assignmentRowLayout(for: width))
          .padding(28).frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    @ViewBuilder
    func sectionContent(assignmentLayout: ProfileAssignmentRowLayout) -> some View {
      switch selectedSection {
      case .assignments: assignmentsSection(rowLayout: assignmentLayout)
      case .combinations:
        ProfileCombinationsSection(
          profile: draft.profile,
          openSheet: { activeSheet = $0 },
          removeChord: removeChord,
          removeSequence: removeSequence
        )
      case .layers:
        ProfileLayersSection(
          profile: draft.profile,
          openSheet: { activeSheet = $0 },
          removeLayer: removeLayer,
          removeBinding: removeLayerBinding
        )
      case .controller:
        ProfileControllerSection(
          profile: draft.profile,
          openSheet: { activeSheet = $0 },
          updateOutputPolicy: { policy in applyDraftChange { try draft.settingOutputPolicy(policy) }
          },
          updatePhysicalColor: { color in applyDraftChange { try draft.settingPhysicalColor(color) }
          }
        )
      }
    }

    func assignmentsSection(rowLayout: ProfileAssignmentRowLayout) -> some View {
      VStack(alignment: .leading, spacing: 18) {
        HStack(alignment: .firstTextBaseline) {
          Text(OJDLocalized.string("common.assignments", fallback: "Assignments")).font(.headline)
          Spacer()
          Button(OJDLocalized.string("common.addAssignment", fallback: "Add assignment")) {
            activeSheet = .capture
          }
        }
        if draft.profile.bindings.isEmpty {
          EmptyStateView(
            symbol: "plus.circle",
            title: OJDLocalized.string("profiles.noAssignments", fallback: "No assignments yet"),
            message: OJDLocalized.string(
              "profiles.assignmentInstructions",
              fallback: "Add a controller control, then choose its keyboard or pointer destination."
            )
          )
        } else {
          ForEach(bindingGroups, id: \.title) { group in
            AssignmentGroupView(
              title: group.title,
              bindings: group.bindings,
              draft: $editor.draft,
              isEditingDisabled: isEditingDisabled,
              onRemove: removeBinding,
              onError: { localError = $0 },
              onAdjust: { activeSheet = .adjustment($0) },
              onBehavior: { activeSheet = .behavior($0) },
              onEditingStateChanged: {
                localError = nil
                saveError = nil
                reportEditingState()
              },
              rowLayout: rowLayout
            )
          }
        }
      }
    }

    var editorFooter: some View {
      VStack(alignment: .leading, spacing: 8) {
        if let localError {
          Text(localError).font(.caption).foregroundColor(Color(NSColor.systemRed)).fixedSize(
            horizontal: false,
            vertical: true
          )
        }
        HStack(spacing: 10) {
          OJDDestructiveButton(action: onDelete) {
            Text(OJDLocalized.string("common.delete", fallback: "Delete"))
          }.disabled(isMutationActive)
          Spacer(minLength: 8)
          saveStatusView
          Button(OJDLocalized.string("common.save", fallback: "Save")) { save() }.disabled(
            draft.profile == expectedCurrent || saveInFlight || isMutationActive
          )
        }
      }.padding(.horizontal, 28).padding(.vertical, 14)
    }

    @ViewBuilder
    var saveStatusView: some View {
      HStack(spacing: 6) {
        if saveStatus == .saving { OJDLoadingIndicator() }
        Text(saveStatus.label).foregroundColor(saveStatus.color)
      }.frame(minHeight: 28).ojdAccessibilityLabel(
        OJDLocalized.string("profiles.saveStatus", fallback: "Profile save status")
      ).ojdAccessibilityValue(saveStatus.accessibilityValue)
    }

    var isMutationActive: Bool {
      if saveInFlight { return true }
      if viewModel.activeMutationOperation != nil { return true }
      if case .saving = viewModel.mutationState { return true }
      return false
    }

    var isEditingDisabled: Bool { isEditingBlocked || isMutationActive }

    var saveStatus: ProfileSaveStatus {
      if saveInFlight { return .saving }
      if saveError != nil { return .error }
      if draft.profile != expectedCurrent { return .unsaved }
      return .saved
    }

    var nameBinding: Binding<String> {
      Binding(
        get: { draft.profile.name },
        set: { newValue in
          guard !isEditingDisabled else { return }
          draft = draft.settingName(newValue)
          saveError = nil
          reportEditingState()
        }
      )
    }

    var bindingGroups: [BindingGroup] {
      let grouped = Dictionary(grouping: draft.profile.bindings) { profileSourceGroup($0.source) }
      return BindingGroup.Order.allCases.compactMap { order in
        guard let bindings = grouped[order.title], !bindings.isEmpty else { return nil }
        return BindingGroup(title: order.title, bindings: bindings)
      }
    }

  }

#endif
