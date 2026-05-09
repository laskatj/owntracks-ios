import SwiftUI
import UIKit

@objc class DeviceDetailHostingController: UIHostingController<AnyView> {

    @objc init(waypoint: Waypoint) {
        let vm = DeviceDetailViewModel(waypoint: waypoint)
        super.init(rootView: AnyView(DeviceDetailView(vm: vm)))
        title = waypoint.belongsTo?.nameOrTopic ?? ""
    }

    @objc required init?(coder: NSCoder) {
        super.init(coder: coder, rootView: AnyView(EmptyView()))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = false
    }
}
