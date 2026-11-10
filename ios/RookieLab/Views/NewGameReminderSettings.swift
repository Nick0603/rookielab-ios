import SwiftUI

struct NewGameReminderSettings: View {
  @Environment(AppModel.self) private var app
  @State private var monitor = NewGameMonitor.shared
  @State private var permissionChecked = false
  var body: some View {
    Form {
      Section {
        Toggle("有新棋局時提醒我", isOn: Binding(get: { monitor.enabled }, set: { on in
          if on { Task { await monitor.requestPermission(); permissionChecked = true } } else { monitor.enabled = false }
        })).accessibilityIdentifier("new-game-reminder-toggle")
        if permissionChecked && !monitor.enabled {
          Text("通知未開啟，可到 iOS 設定允許 Rookie Lab 通知。")
          Link("開啟 iOS 設定", destination: URL(string: UIApplication.openSettingsURLString)!)
        }
        if !RemotePush.shared.active {
          Picker("偏好提醒時間", selection: $monitor.hour) {
            ForEach(9..<22) { hour in Text("\(hour):00").tag(hour) }
          }
        }
      } footer: {
        if RemotePush.shared.active {
          Text("下完棋約 10–20 分鐘後提醒。多個帳號合併，每天最多一則；22:00–09:00 不打擾。")
        } else {
          Text("多個帳號合併提醒，每天最多一則，至少間隔 24 小時。22:00–09:00 休息；背景檢查時間由 iOS 安排。")
        }
      }
      Section("追蹤的棋站帳號") {
        ForEach(app.accounts) { a in
          if AccountHistory.verified(a) {
            Toggle(isOn: Binding(get: { !monitor.excluded.contains(a.id) }, set: { on in
              if on { monitor.excluded.remove(a.id) } else { monitor.excluded.insert(a.id) }
            })) {
              VStack(alignment: .leading) {
                Text("\(a.platform.name) · \(a.username)")
                Text(monitor.status(a)).font(.caption).foregroundStyle(.secondary)
              }
            }
          } else { Text("\(a.username)：請先載入對局確認帳號") }
        }
        if app.accounts.isEmpty { Text("先輸入棋站帳號，再開啟新棋局提醒。") }
      }
      Section {
        Text("沒有新棋局時不提醒；打開 App 後，已出現的新棋局不再另外提醒。首次加入帳號不補發歷史對局。")
        Text("開啟提醒後，追蹤的棋站帳號名稱與這台裝置的通知代碼會傳到 Rookie Lab 伺服器，只用來檢查新對局；關閉提醒即刪除。")
      }
    }.navigationTitle("新棋局提醒").navigationBarTitleDisplayMode(.inline)
  }
}
