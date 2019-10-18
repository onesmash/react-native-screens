#import "RNSScreenStack.h"
#import "RNSScreen.h"
#import "RNSScreenStackHeaderConfig.h"

#import <React/RCTBridge.h>
#import <React/RCTUIManager.h>
#import <React/RCTUIManagerUtils.h>
#import <React/RCTShadowView.h>

@interface RNSScreenStackView () <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@end

@interface RNSScreenStackAnimator : NSObject <UIViewControllerAnimatedTransitioning>
- (instancetype)initWithOperation:(UINavigationControllerOperation)operation;
@end

@implementation RNSScreenStackView {
  BOOL _needUpdate;
  UINavigationController *_controller;
  NSMutableArray<RNSScreenView *> *_reactSubviews;
  NSMutableSet<RNSScreenView *> *_dismissedScreens;
  NSMutableArray<UIViewController *> *_presentedModals;
  __weak RNSScreenStackManager *_manager;
}

- (instancetype)initWithManager:(RNSScreenStackManager*)manager
{
  if (self = [super init]) {
    _manager = manager;
    _reactSubviews = [NSMutableArray new];
    _presentedModals = [NSMutableArray new];
    _dismissedScreens = [NSMutableSet new];
    _controller = [[UINavigationController alloc] init];
    _controller.delegate = self;
    _needUpdate = NO;
    [self addSubview:_controller.view];
    _controller.interactivePopGestureRecognizer.delegate = self;
  }
  return self;
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
  UIView *view = viewController.view;
  RNSScreenStackHeaderConfig *config = nil;
  for (UIView *subview in view.reactSubviews) {
    if ([subview isKindOfClass:[RNSScreenStackHeaderConfig class]]) {
      config = (RNSScreenStackHeaderConfig*) subview;
      break;
    }
  }
  [RNSScreenStackHeaderConfig willShowViewController:viewController withConfig:config];
}

- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    for (UIViewController *vc in _controller.viewControllers.reverseObjectEnumerator) {
        if([vc.view isMemberOfClass:RNSScreenView.class]) {
            viewController = vc;
            break;
        }
    }
  for (NSUInteger i = _reactSubviews.count; i > 0; i--) {
    if ([viewController isEqual:[_reactSubviews objectAtIndex:i - 1].controller]) {
      break;
    } else {
      // TODO: send dismiss event
      [_dismissedScreens addObject:[_reactSubviews objectAtIndex:i - 1]];
    }
  }
}

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController animationControllerForOperation:(UINavigationControllerOperation)operation fromViewController:(UIViewController *)fromVC toViewController:(UIViewController *)toVC
{
  RNSScreenView *screen;
  if (operation == UINavigationControllerOperationPush) {
    if(![toVC.view isKindOfClass:RNSScreenView.class]) {
      return nil;	       
    }
    screen = (RNSScreenView *) toVC.view;
  } else if (operation == UINavigationControllerOperationPop) {
    if(![fromVC.view isKindOfClass:RNSScreenView.class]) {
      return nil;
    }
    screen = (RNSScreenView *) fromVC.view;
  }
  if (screen != nil && screen.stackAnimation != RNSScreenStackAnimationDefault) {
    return  [[RNSScreenStackAnimator alloc] initWithOperation:operation];
  }
  return nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
  // cancel touches in parent, this is needed to cancel RN touch events. For example when Touchable
  // item is close to an edge and we start pulling from edge we want the Touchable to be cancelled.
  // Without the below code the Touchable will remain active (highlighted) for the duration of back
  // gesture and onPress may fire when we release the finger.
  UIView *parent = _controller.view;
  while (parent != nil && ![parent isKindOfClass:[RCTRootView class]]) parent = parent.superview;
  RCTRootView *rootView = (RCTRootView *)parent;
  [rootView cancelTouches];

  return _controller.viewControllers.count > 1;
}

- (void)markUpdated
{
  // We want 'updateContainer' to be executed on main thread after all enqueued operations in
  // uimanager are complete. In order to achieve that we enqueue call on UIManagerQueue from which
  // we enqueue call on the main queue. This seems to be working ok in all the cases I've tried but
  // there is a chance it is not the correct way to do that.
  if (!_needUpdate) {
    _needUpdate = YES;
    RCTExecuteOnUIManagerQueue(^{
      RCTExecuteOnMainQueue(^{
        _needUpdate = NO;
        [self updateContainer];
      });
    });
  }
}

- (void)markChildUpdated
{
  // do nothing
}

- (void)didUpdateChildren
{
  // do nothing
}

- (void)insertReactSubview:(RNSScreenView *)subview atIndex:(NSInteger)atIndex
{
  if (![subview isKindOfClass:[RNSScreenView class]]) {
    RCTLogError(@"ScreenStack only accepts children of type Screen");
    return;
  }
  [_reactSubviews insertObject:subview atIndex:atIndex];
  [self markUpdated];
}

- (void)removeReactSubview:(RNSScreenView *)subview
{
  [_reactSubviews removeObject:subview];
  [_dismissedScreens removeObject:subview];
  [self markUpdated];
}

- (NSArray<UIView *> *)reactSubviews
{
  return _reactSubviews;
}

- (void)didUpdateReactSubviews
{
  // do nothing
}

- (void)setModalViewControllers:(NSArray<UIViewController *> *)controllers
{
  NSMutableArray<UIViewController *> *newControllers = [NSMutableArray arrayWithArray:controllers];
  [newControllers removeObjectsInArray:_presentedModals];

  NSMutableArray<UIViewController *> *controllersToRemove = [NSMutableArray arrayWithArray:_presentedModals];
  [controllersToRemove removeObjectsInArray:controllers];

  // presenting new controllers
  for (UIViewController *newController in newControllers) {
    [_presentedModals addObject:newController];
    if (_controller.presentedViewController != nil) {
      [_controller.presentedViewController presentViewController:newController animated:YES completion:nil];
    } else {
      [_controller presentViewController:newController animated:YES completion:nil];
    }
  }

  // hiding old controllers
  for (UIViewController *controller in [controllersToRemove reverseObjectEnumerator]) {
    [_presentedModals removeObject:controller];
    if (controller.presentedViewController != nil) {
      UIViewController *restore = controller.presentedViewController;
      UIViewController *parent = controller.presentingViewController;
      [controller dismissViewControllerAnimated:NO completion:^{
        [parent dismissViewControllerAnimated:NO completion:^{
          [parent presentViewController:restore animated:NO completion:nil];
        }];
      }];
    } else {
      [controller.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    }
  }
}

- (void)setPushViewControllers:(NSArray<UIViewController *> *)controllers
{
    UIViewController *top = controllers.lastObject;
    UIViewController *lastTop = _controller.viewControllers.lastObject;
    __block UIViewController *secondLastTop = nil;
    [_controller.viewControllers enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(UIViewController *vc, NSUInteger idx, BOOL *stop) {
        if([vc.view isKindOfClass:RNSScreenView.class] && idx < _controller.viewControllers.count - 1) {
            secondLastTop = vc;
            *stop = YES;
        }
    }];

    BOOL shouldAnimate = YES;
    if([lastTop.view isKindOfClass:RNSScreenView.class]) {
        shouldAnimate =  ((RNSScreenView *) lastTop.view).stackAnimation != RNSScreenStackAnimationNone;
    } else if ([secondLastTop.view isKindOfClass:RNSScreenView.class]) {
        shouldAnimate =  ((RNSScreenView *) secondLastTop.view).stackAnimation != RNSScreenStackAnimationNone;
    }

    if (_controller.viewControllers.count == 0) {
    // nothing pushed yet
    [_controller setViewControllers:@[top] animated:NO];
    } else if (top != lastTop) {
      if([_controller.viewControllers containsObject:top]) {
          if([lastTop.view isKindOfClass:RNSScreenView.class]) {
              [_controller popViewControllerAnimated:shouldAnimate];
          }
      } else {
          [_controller pushViewController:top animated:shouldAnimate];
      }
    }
}

- (void)updateContainer
{
  NSMutableArray<UIViewController *> *pushControllers = [NSMutableArray new];
  NSMutableArray<UIViewController *> *modalControllers = [NSMutableArray new];
  for (RNSScreenView *screen in _reactSubviews) {
    if (![_dismissedScreens containsObject:screen]) {
      if (pushControllers.count == 0) {
        // first screen on the list needs to be places as "push controller"
        [pushControllers addObject:screen.controller];
      } else {
        if (screen.stackPresentation == RNSScreenStackPresentationPush) {
          [pushControllers addObject:screen.controller];
        } else {
          [modalControllers addObject:screen.controller];
        }
      }
    }
  }

  [self setPushViewControllers:pushControllers];
  [self setModalViewControllers:modalControllers];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  [self reactAddControllerToClosestParent:_controller];
  _controller.view.frame = self.bounds;
}

- (void)dismissOnReload
{
  dispatch_async(dispatch_get_main_queue(), ^{
    for (UIViewController *controller in self->_presentedModals) {
      [controller dismissViewControllerAnimated:NO completion:nil];
    }
  });
}

@end

@implementation RNSScreenStackManager {
  NSPointerArray *_stacks;
}

RCT_EXPORT_MODULE()

RCT_EXPORT_VIEW_PROPERTY(transitioning, NSInteger)
RCT_EXPORT_VIEW_PROPERTY(progress, CGFloat)

- (UIView *)view
{
  RNSScreenStackView *view = [[RNSScreenStackView alloc] initWithManager:self];
  if (!_stacks) {
    _stacks = [NSPointerArray weakObjectsPointerArray];
  }
  [_stacks addPointer:(__bridge void *)view];
  return view;
}

- (void)invalidate
{
 for (RNSScreenStackView *stack in _stacks) {
   [stack dismissOnReload];
 }
 _stacks = nil;
}

@end

@implementation RNSScreenStackAnimator {
  UINavigationControllerOperation _operation;
}

- (instancetype)initWithOperation:(UINavigationControllerOperation)operation
{
  if (self = [super init]) {
    _operation = operation;
  }
  return self;
}

- (NSTimeInterval)transitionDuration:(id <UIViewControllerContextTransitioning>)transitionContext
{
  RNSScreenView *screen;
  if (_operation == UINavigationControllerOperationPush) {
    UIViewController* toViewController = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
    screen = (RNSScreenView *)toViewController.view;
  } else if (_operation == UINavigationControllerOperationPop) {
    UIViewController* fromViewController = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    screen = (RNSScreenView *)fromViewController.view;
  }

  if (screen != nil && screen.stackAnimation == RNSScreenStackAnimationNone) {
    return 0;
  }
  return 0.35; // default duration
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
  UIViewController* toViewController = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
  UIViewController* fromViewController = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];

  if (_operation == UINavigationControllerOperationPush) {
    [[transitionContext containerView] addSubview:toViewController.view];
    toViewController.view.alpha = 0.0;
    [UIView animateWithDuration:[self transitionDuration:transitionContext] animations:^{
      toViewController.view.alpha = 1.0;
    } completion:^(BOOL finished) {
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
  } else if (_operation == UINavigationControllerOperationPop) {
    [[transitionContext containerView] insertSubview:toViewController.view belowSubview:fromViewController.view];

    [UIView animateWithDuration:[self transitionDuration:transitionContext] animations:^{
      fromViewController.view.alpha = 0.0;
    } completion:^(BOOL finished) {
      [transitionContext completeTransition:![transitionContext transitionWasCancelled]];
    }];
  }
}

@end
