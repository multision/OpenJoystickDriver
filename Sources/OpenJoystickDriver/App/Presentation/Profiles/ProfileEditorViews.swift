#if canImport(SwiftUI)

  import AppKit
  import Foundation
  import OpenJoystickDriverKit
  import SwiftUI

  // MARK: - Profile editor

  struct ProfileEditorView: View {
    let profile: RemappingProfile
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

    @State
    private var draft: RuntimeProfileDraft
    @State
    private var expectedCurrent: RemappingProfile
    @State
    private var activeSheet: ProfileEditorSheet?
    @State
    private var showingConflict = false
    @State
    private var localError: String?
    @State
    private var saveError: String?
    @State
    private var saveState = ProfileEditorSaveState()

    init(
      profile: RemappingProfile,
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
      self.viewModel = viewModel
      self.isActive = isActive
      self.isEditingBlocked = isEditingBlocked
      _selectedSection = selectedSection
      self.onDelete = onDelete
      self.onExport = onExport
      self.onEditingStateChanged = onEditingStateChanged
      self.onMutationStarted = onMutationStarted
      self.onMutationResult = onMutationResult
      _draft = State(initialValue: RuntimeProfileDraft(profile: profile))
      _expectedCurrent = State(initialValue: profile)
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
      }.disabled(isEditingDisabled).sheet(item: $activeSheet) { sheet in
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

    private func editorHeader(width: CGFloat) -> some View {
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
    private var profileFacts: some View {
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
    private var primaryActivationAction: some View {
      if profile.joyConPair == nil {
        Button(
          OJDLocalized.string(
            isActive ? "common.deactivate" : "common.setActive",
            fallback: isActive ? "Deactivate" : "Set active"
          )
        ) { isActive ? deactivateProfile() : activateProfile() }.disabled(isMutationActive)
      }
    }

    private var profileActionMenu: some View {
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

    private func sectionNavigation(width: CGFloat) -> some View {
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

    private func editorContent(width: CGFloat) -> some View {
      ScrollView {
        sectionContent(assignmentLayout: ProfilePresentationPolicy.assignmentRowLayout(for: width))
          .padding(28).frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    @ViewBuilder
    private func sectionContent(assignmentLayout: ProfileAssignmentRowLayout) -> some View {
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

    private func assignmentsSection(rowLayout: ProfileAssignmentRowLayout) -> some View {
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
              draft: $draft,
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

    private var editorFooter: some View {
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
    private var saveStatusView: some View {
      HStack(spacing: 6) {
        if saveStatus == .saving { OJDLoadingIndicator() }
        Text(saveStatus.label).foregroundColor(saveStatus.color)
      }.frame(minHeight: 28).ojdAccessibilityLabel(
        OJDLocalized.string("profiles.saveStatus", fallback: "Profile save status")
      ).ojdAccessibilityValue(saveStatus.accessibilityValue)
    }

    private var isMutationActive: Bool {
      if saveInFlight { return true }
      if viewModel.activeMutationOperation != nil { return true }
      if case .saving = viewModel.mutationState { return true }
      return false
    }

    private var isEditingDisabled: Bool { isEditingBlocked || isMutationActive }

    private var saveStatus: ProfileSaveStatus {
      if saveInFlight { return .saving }
      if saveError != nil { return .error }
      if draft.profile != expectedCurrent { return .unsaved }
      return .saved
    }

    private var nameBinding: Binding<String> {
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

    private var bindingGroups: [BindingGroup] {
      let grouped = Dictionary(grouping: draft.profile.bindings) { profileSourceGroup($0.source) }
      return BindingGroup.Order.allCases.compactMap { order in
        guard let bindings = grouped[order.title], !bindings.isEmpty else { return nil }
        return BindingGroup(title: order.title, bindings: bindings)
      }
    }

    private func addBinding(source: RemappingSource, destination: RemappingDestination) {
      guard !isEditingDisabled else { return }
      do {
        draft = try draft.addingBinding(source: source, destination: destination)
        activeSheet = nil
        saveError = nil
        reportEditingState()
      } catch { localError = RuntimePresentation.userFacingError(error) }
    }

    private func removeBinding(_ id: UUID) {
      guard !isEditingDisabled else { return }
      do {
        draft = try draft.removingBinding(id)
        saveError = nil
        reportEditingState()
      } catch { localError = RuntimePresentation.userFacingError(error) }
    }

    private func updateAxisTuning(_ tuning: RemappingAxisTuning, for id: UUID) {
      guard !isEditingDisabled else { return }
      do {
        draft = try draft.settingAxisTuning(tuning, for: id)
        saveError = nil
        reportEditingState()
      } catch { localError = RuntimePresentation.userFacingError(error) }
    }

    private func updateMetadata(_ profile: RemappingProfile) {
      guard !isEditingDisabled else { return }
      draft = RuntimeProfileDraft(profile: profile)
      localError = nil
      saveError = nil
      reportEditingState()
    }

    private var activationLabel: String {
      if profile.joyConPair != nil {
        return OJDLocalized.string("profiles.joyConSessionState", fallback: "Explicit pairing")
      }
      return OJDLocalized.string(
        isActive ? "profiles.active" : "profiles.notActive",
        fallback: isActive ? "Active" : "Not active"
      )
    }

    private func assignmentCountLabel(_ count: Int) -> String {
      OJDLocalized.plural("profiles.assignments", count: count, fallback: "%d assignments")
    }

    private var menuActions: [ProfileEditorMenuAction] {
      var actions: [ProfileEditorMenuAction] = [.duplicate, .export, .details]
      if isActive, profile.joyConPair == nil { actions.append(.deactivateAll) }
      return actions
    }

    private func performMenuAction(_ action: ProfileEditorMenuAction) {
      switch action {
      case .duplicate: duplicateProfile()
      case .export:
        do { onExport(try draft.validatedProfile()) } catch {
          localError = RuntimePresentation.userFacingError(error)
        }
      case .details: activeSheet = .metadata
      case .deactivateAll: deactivateAllProfiles()
      }
    }

    private func activateProfile() {
      guard !isMutationActive else { return }
      let request = RuntimeMutationRequest(operation: .activate(profileID: profile.id))
      guard onMutationStarted(request) else { return }
      Task { @MainActor in
        let result = await viewModel.activateRemappingProfile(id: profile.id, request: request)
        onMutationResult(result)
      }
    }

    private func deactivateProfile() {
      guard !isMutationActive else { return }
      let request = RuntimeMutationRequest(operation: .deactivate(profileID: profile.id))
      guard onMutationStarted(request) else { return }
      Task { @MainActor in
        let result = await viewModel.deactivateRemappingProfile(
          profileID: profile.id,
          request: request
        )
        onMutationResult(result)
      }
    }

    private func deactivateAllProfiles() {
      guard !isMutationActive else { return }
      let request = RuntimeMutationRequest(operation: .deactivate(profileID: nil))
      guard onMutationStarted(request) else { return }
      Task { @MainActor in
        let result = await viewModel.deactivateRemappingProfile(
          vendorID: profile.device.vendorID,
          productID: profile.device.productID,
          request: request
        )
        onMutationResult(result)
      }
    }

    private func addChord(
      sources: [RemappingSource],
      mode: RemappingChordMode,
      windowMs: Double,
      destination: RemappingDestination
    ) {
      applyDraftChange {
        try draft.addingChord(
          sources: Set(sources),
          destination: destination,
          mode: mode,
          windowMs: windowMs
        )
      }
    }

    private func removeChord(_ id: UUID) { applyDraftChange { try draft.removingChord(id) } }

    private func addSequence(
      sources: [RemappingSource],
      windowMs: Double,
      destination: RemappingDestination
    ) {
      applyDraftChange {
        try draft.addingSequence(sources: sources, windowMs: windowMs, destination: destination)
      }
    }

    private func removeSequence(_ id: UUID) { applyDraftChange { try draft.removingSequence(id) } }

    private func addLayer(name: String, activator: RemappingSource, mode: RemappingLayerActivation)
    {
      applyDraftChange {
        try draft.addingLayer(name: name, activator: activator, activationMode: mode)
      }
    }

    private func removeLayer(_ id: UUID) { applyDraftChange { try draft.removingLayer(id) } }

    private func setLayerBinding(
      layerID: UUID,
      source: RemappingSource,
      destination: RemappingDestination
    ) {
      applyDraftChange {
        try draft.settingLayerBinding(layerID: layerID, source: source, destination: destination)
      }
    }

    private func removeLayerBinding(layerID: UUID, bindingID: UUID) {
      applyDraftChange { try draft.removingLayerBinding(layerID: layerID, bindingID: bindingID) }
    }

    private func updateLayerAxisTuning(
      _ tuning: RemappingAxisTuning,
      layerID: UUID,
      bindingID: UUID
    ) {
      applyDraftChange {
        try draft.settingLayerBindingAxisTuning(
          layerID: layerID,
          bindingID: bindingID,
          axisTuning: tuning
        )
      }
    }

    private func applyDraftChange(_ change: () throws -> RuntimeProfileDraft) {
      guard !isEditingDisabled else { return }
      do {
        draft = try change()
        localError = nil
        saveError = nil
        reportEditingState()
      } catch { localError = RuntimePresentation.userFacingError(error) }
    }

    private func save() {
      guard draft.profile != expectedCurrent, !saveInFlight, !isEditingDisabled else { return }
      let operation = RuntimeMutationOperation.update(profileID: profile.id)
      let request = RuntimeMutationRequest(operation: operation)
      guard saveState.begin(request) else { return }
      saveError = nil
      localError = nil
      guard onMutationStarted(request) else {
        finishSave()
        return
      }
      reportEditingState()
      Task { @MainActor in
        let result = await viewModel.updateRemappingProfile(
          draft.profile,
          expectedCurrent: expectedCurrent,
          request: request
        )
        reconcileSave(request: request, result: result)
        onMutationResult(result)
      }
    }

    private func duplicateProfile() {
      guard !isEditingDisabled else { return }
      let source = draft.profile
      let duplicate = duplicatedProfile(source)
      let request = RuntimeMutationRequest(operation: .create(profileID: duplicate.id))
      guard onMutationStarted(request) else { return }
      Task { @MainActor in
        let result = await viewModel.createRemappingProfile(duplicate, request: request)
        onMutationResult(result)
      }
    }

    private func reportEditingState() {
      onEditingStateChanged(saveInFlight || draft.profile != expectedCurrent)
    }

    private func handleMutation(_ mutation: RuntimeMutationState) {
      guard saveInFlight, pendingUpdateOperation == .update(profileID: profile.id),
        viewModel.lastMutationOperation == pendingUpdateOperation,
        viewModel.lastMutationID == pendingUpdateMutationID
      else { return }

      switch mutation {
      case .conflict(let profileID) where profileID == profile.id: applySaveConflict()
      case .error(let message):
        finishSave()
        localError = message
        saveError = message
      case .succeeded(let profileID) where profileID == profile.id: applySaveSuccess()
      default: return
      }
      reportEditingState()
    }

    private func finishSave() { saveState.cancel() }

    private func reconcileSave(request: RuntimeMutationRequest, result: RuntimeMutationResult) {
      guard saveInFlight, pendingUpdateOperation == request.operation,
        pendingUpdateMutationID == request.id
      else { return }
      switch saveState.resolve(result) {
      case .succeeded: applySaveSuccess()
      case .conflict: applySaveConflict()
      case .failed(let message):
        finishSave()
        localError = message
        saveError = message
      case .ignored: return
      }
      reportEditingState()
    }

    private func applySaveConflict() {
      finishSave()
      showingConflict = true
      saveError = OJDLocalized.string(
        "profiles.changedElsewhere",
        fallback: "The profile changed elsewhere."
      )
    }

    private func applySaveSuccess() {
      finishSave()
      saveError = nil
      guard case .available(let snapshot) = viewModel.remappingState,
        let latest = snapshot.profiles.first(where: { $0.id == profile.id })
      else {
        localError = OJDLocalized.string(
          "profiles.savedButUnavailable",
          fallback: "The profile was saved, but its latest state is unavailable."
        )
        saveError = localError
        return
      }
      expectedCurrent = latest
      draft = RuntimeProfileDraft(profile: latest)
    }

    private var saveInFlight: Bool { saveState.isInFlight }

    private var pendingUpdateOperation: RuntimeMutationOperation? { saveState.operation }

    private var pendingUpdateMutationID: UUID? { saveState.mutationID }
  }

  private enum ProfileEditorMenuAction: Hashable {
    case duplicate
    case export
    case details
    case deactivateAll

    var title: String {
      switch self {
      case .duplicate: return OJDLocalized.string("common.duplicate", fallback: "Duplicate")
      case .export: return OJDLocalized.string("profiles.export", fallback: "Export")
      case .details: return OJDLocalized.string("profiles.details", fallback: "Details")
      case .deactivateAll:
        return OJDLocalized.string("profiles.deactivateController", fallback: "Deactivate all")
      }
    }
  }

#endif
