import SwiftUI

struct LicensesView: View {
    private let items: [(name: String, license: String, url: String, note: String?)] = [
        ("雾凇拼音 rime-ice", "GPL-3.0", "https://github.com/iDvel/rime-ice",
         "键盘内置拼音词库（基础词库与 8105 字表）取自雾凇拼音，按 GPL-3.0 分发，许可全文见 https://www.gnu.org/licenses/gpl-3.0.html"),
        ("librime", "BSD-3-Clause", "https://github.com/rime/librime", nil),
        ("Boost", "BSL-1.0", "https://www.boost.org", nil),
        ("LevelDB", "BSD-3-Clause", "https://github.com/google/leveldb", nil),
        ("marisa-trie", "BSD-2-Clause / LGPL-2.1", "https://github.com/s-yata/marisa-trie", nil),
        ("yaml-cpp", "MIT", "https://github.com/jbeder/yaml-cpp", nil),
        ("OpenCC", "Apache-2.0", "https://github.com/BYVoid/OpenCC", nil),
        ("darts-clone", "BSD-2-Clause", "https://github.com/s-yata/darts-clone", nil),
    ]

    var body: some View {
        List(items, id: \.name) { item in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(item.license).foregroundStyle(.secondary)
                }
                if let note = item.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
                Link(item.url, destination: URL(string: item.url)!).font(.footnote)
            }
        }
        .navigationTitle("开源许可")
    }
}
