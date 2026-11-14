import MapKit
import SwiftUI
import TaktAPI

/// 新建任务: slides up from the bottom over a scrim. Creates at the end of the current level.
/// Fields: 名称, 地点 (with 地点联想); 前置条件 are folded until "+ 前置条件" adds a row.
/// Only a place picked from the suggestions is located; free text stays 未定位.
struct NewTaskSheet: View {
    let model: LevelModel
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce

    private struct Entry: Identifiable { let id = UUID(); var text = "" }
    private enum Field: Hashable { case name, place, pre(UUID) }

    @State private var name = ""
    @State private var place = ""
    /// The suggestion picked for 地点; cleared as soon as the text is edited again.
    @State private var picked: PlaceChoice?
    @State private var search = PlaceSearch()
    @State private var pres: [Entry] = []
    @State private var submitting = false
    @FocusState private var focus: Field?

    var body: some View {
        // Closed = not in the hierarchy at all (so VoiceOver and UI tests never find its buttons);
        // the transitions keep the slide / fade. Field state lives on this container, so it survives.
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                    .accessibilityLabel("关闭")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)

                form
                    .transition(reduce ? .opacity : .move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .motion(Motion.sheet, value: isPresented, reduce: reduce)
        .onChange(of: isPresented) { _, open in
            if open {
                Task {
                    try? await Task.sleep(for: .milliseconds(reduce ? 0 : 320))
                    focus = .name
                }
            } else {
                focus = nil
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("新建任务").font(.system(size: 18, weight: .bold)).foregroundStyle(Palette.text)
                Spacer()
                Text(model.name).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            LabeledField(label: "名称", text: $name)
                .focused($focus, equals: .name)
                .submitLabel(.next)
                .onSubmit { focus = .place }
            placeField

            VStack(alignment: .leading, spacing: 8) {
                ForEach($pres) { $entry in
                    HStack(spacing: 8) {
                        InputField(text: $entry.text, placeholder: "如：购票、预约")
                            .focused($focus, equals: .pre(entry.id))
                            .accessibilityLabel("前置条件 \(index(of: entry.id) + 1)")
                        Button {
                            remove(entry.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 48, height: 48)
                                .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除前置条件 \(index(of: entry.id) + 1)")
                    }
                    .transition(reduce ? .opacity : .offset(x: 28).combined(with: .opacity))
                }
                Button(action: addPrerequisite) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text("前置条件").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Palette.accentText)
                    .frame(minHeight: Metrics.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                WideButton(title: "取消", kind: .secondary, height: 48, action: close)
                WideButton(title: "添加", kind: .primary, height: 48, busy: submitting, action: submit)
                    .disabled(submitting)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.18), radius: 16, y: -8)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 地点 + suggestions (title, grey address). A pick fills the field and shows the pin.
    private var placeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("地点").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            TextField("", text: $place)
                .font(.system(size: 16))
                .foregroundStyle(Palette.text)
                .padding(.leading, 14)
                .padding(.trailing, 44)
                .frame(height: 48)
                .background(Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius)
                        .strokeBorder(picked == nil ? Palette.line : Palette.accent, lineWidth: 1)
                )
                .overlay(alignment: .trailing) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.accentText)
                        .padding(.trailing, 14)
                        .opacity(picked == nil ? 0 : 1)
                        .accessibilityHidden(true)
                }
                .focused($focus, equals: .place)
                .submitLabel(.done)
                .onSubmit(submit)
                .accessibilityLabel(picked == nil ? "地点" : "地点，已定位")
                .onChange(of: place) { _, text in
                    if let p = picked, p.name != text { picked = nil }
                    if picked == nil { search.update(text) }
                }

            if showSuggestions {
                VStack(spacing: 0) {
                    ForEach(search.suggestions) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "mappin")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.muted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Palette.text)
                                    if !s.subtitle.isEmpty {
                                        Text(s.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Palette.muted)
                                    }
                                }
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(s.title)，\(s.subtitle)")
                    }
                }
                .padding(.vertical, 4)
                .background(Palette.bg, in: RoundedRectangle(cornerRadius: Metrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: Metrics.controlRadius).strokeBorder(Palette.line, lineWidth: 1))
                .transition(.opacity)
            }
        }
        .motion(Motion.fade, value: showSuggestions, reduce: reduce)
        .onAppear { search.bias(to: model.items.compactMap(Self.coordinate)) }
    }

    private var showSuggestions: Bool {
        focus == .place && picked == nil && !place.isEmpty && !search.suggestions.isEmpty
    }

    private static func coordinate(_ t: TaskSummary) -> CLLocationCoordinate2D? {
        guard let lat = t.lat, let lng = t.lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    private func pick(_ s: PlaceSearch.Suggestion) {
        Task {
            guard let choice = await search.resolve(s) else { return }
            picked = choice
            place = choice.name
            search.clear()
        }
    }

    private func index(of id: UUID) -> Int { pres.firstIndex { $0.id == id } ?? 0 }

    private func addPrerequisite() {
        let e = Entry()
        Motion.with(Motion.settle, reduce: reduce) { pres.append(e) }
        focus = .pre(e.id)
    }

    private func remove(_ id: UUID) {
        Motion.with(Motion.settle, reduce: reduce) { pres.removeAll { $0.id == id } }
    }

    private func submit() {
        guard !submitting else { return }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            focus = .name
            return
        }
        submitting = true
        Task {
            let ok = await model.create(
                name: name, place: place, location: picked, prerequisites: pres.map(\.text))
            submitting = false
            if ok {
                close()
                name = ""
                place = ""
                picked = nil
                search.clear()
                pres = []
            }
        }
    }

    private func close() {
        Motion.with(Motion.sheet, reduce: reduce) { isPresented = false }
    }
}
