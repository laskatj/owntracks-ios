import SwiftUI
import UIKit

@objc class DeviceDetailHostingController: UIViewController {
    private let hostingController: UIHostingController<AnyView>

    @objc init(waypoint: Waypoint) {
        let vm = DeviceDetailViewModel(waypoint: waypoint)
        hostingController = UIHostingController(rootView: AnyView(DeviceDetailView(vm: vm)))
        super.init(nibName: nil, bundle: nil)
        title = waypoint.belongsTo?.nameOrTopic ?? ""
    }

    @objc required init?(coder: NSCoder) {
        hostingController = UIHostingController(rootView: AnyView(EmptyView()))
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.navigationBar.prefersLargeTitles = false
    }
}
