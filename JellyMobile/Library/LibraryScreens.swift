import SwiftUI

// Placeholder screens – replaced by the library work package.

struct HomeScreen: View {
    var body: some View { Text("Start").navigationTitle("Start") }
}

struct LibraryScreen: View {
    let title: String
    let types: [String]
    var parentID: String?
    var personID: String?

    init(title: String, types: [String], parentID: String? = nil, personID: String? = nil) {
        self.title = title
        self.types = types
        self.parentID = parentID
        self.personID = personID
    }

    init(library: BaseItem) {
        self.init(title: library.name, types: ["Movie", "Series"], parentID: library.id)
    }

    var body: some View { Text(title).navigationTitle(title) }
}

struct SearchScreen: View {
    var body: some View { Text("Suche").navigationTitle("Suche") }
}

struct ItemDetailScreen: View {
    let item: BaseItem
    var body: some View { Text(item.name) }
}

struct PersonScreen: View {
    let person: Person
    var body: some View { Text(person.name) }
}
