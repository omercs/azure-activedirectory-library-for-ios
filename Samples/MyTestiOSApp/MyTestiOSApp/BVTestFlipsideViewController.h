// Created by Boris Vidolov on 9/13/13.
// Copyright © Microsoft Open Technologies, Inc.
//
// All Rights Reserved
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
// OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
// ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A
// PARTICULAR PURPOSE, MERCHANTABILITY OR NON-INFRINGEMENT.
//
// See the Apache License, Version 2.0 for the specific language
// governing permissions and limitations under the License.


#import <UIKit/UIKit.h>

@class BVTestFlipsideViewController;

@protocol BVTestFlipsideViewControllerDelegate
- (void)flipsideViewControllerDidFinish:(BVTestFlipsideViewController *)controller;
@end

@interface BVTestFlipsideViewController : UIViewController
{
    NSString* myMember;
}

@property (weak, nonatomic) id <BVTestFlipsideViewControllerDelegate> delegate;

- (IBAction)done:(id)sender;

@end
