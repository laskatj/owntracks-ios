//
//  SettingsTVC.h
//  OwnTracks
//
//  Created by Christoph Krey on 11.09.13.
//  Copyright © 2013-2025  Christoph Krey. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "ABStaticTableViewController.h"

@interface SettingsTVC : ABStaticTableViewController <UIDocumentInteractionControllerDelegate, UITextFieldDelegate>
+ (void)performFullResetToBundledDefaultsFromPresenter:(UIViewController *)presenter
                                               animated:(BOOL)animated
                                             completion:(void (^ _Nullable)(void))completion;
@end
