// Copyright 2015-present 650 Industries. All rights reserved.

#import <AVFoundation/AVFoundation.h>

#import <React/RCTConvert.h>
#import <React/RCTBridge.h>
#import <React/UIView+React.h>
#import <React/RCTUtils.h>

#import "EXAV.h"
#import "EXVideoView.h"
#import "EXAVPlayerData.h"
#import "EXVideoPlayerViewController.h"

static NSString *const EXVideoReadyForDisplayKeyPath = @"readyForDisplay";

@interface EXVideoView ()

@property (nonatomic, weak) EXAV *exAV;

@property (nonatomic, assign) BOOL playerHasLoaded;
@property (nonatomic, strong) EXAVPlayerData *data;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) EXVideoPlayerViewController *playerViewController;

@property (nonatomic, assign) BOOL fullscreenPlayerIsDismissing;
@property (nonatomic, strong) EXVideoPlayerViewController *fullscreenPlayerViewController;
@property (nonatomic, strong) RCTPromiseResolveBlock requestedFullscreenChangeResolver;
@property (nonatomic, strong) RCTPromiseRejectBlock requestedFullscreenChangeRejecter;
@property (nonatomic, assign) BOOL requestedFullscreenChange;

@property (nonatomic, strong) UIViewController *presentingViewController;
@property (nonatomic, assign) BOOL fullscreenPlayerPresented;

@property (nonatomic, strong) NSMutableDictionary *statusToSet;

@end

@implementation EXVideoView

#pragma mark - EXVideoView interface methods

- (instancetype)initWithBridge:(RCTBridge *)bridge
{
  if ((self = [super init])) {
    _exAV = [bridge moduleForClass:[EXAV class]];
    [_exAV registerVideoForAudioLifecycle:self];
    
    _data = nil;
    _playerLayer = nil;
    _playerHasLoaded = NO;
    _playerViewController = nil;
    _presentingViewController = nil;
    _fullscreenPlayerPresented = NO;
    _fullscreenPlayerViewController = nil;
    _requestedFullscreenChangeResolver = nil;
    _requestedFullscreenChangeRejecter = nil;
    _fullscreenPlayerIsDismissing = NO;
    _requestedFullscreenChange = NO;
    _statusToSet = [NSMutableDictionary new];
    _useNativeControls = NO;
    _nativeResizeMode = AVLayerVideoGravityResizeAspectFill;
  }
  
  return self;
}

#pragma mark - callback helper methods

- (void)_callFullscreenCallbackForUpdate:(EXVideoFullscreenUpdate)update
{
  if (_onFullscreenUpdate) {
    _onFullscreenUpdate(@{@"fullscreenUpdate": @(update),
                          @"status": [_data getStatus]});
  }
}

- (void)_callErrorCallback:(NSString *)error
{
  if (_onError) {
    _onError(@{@"error": error});
  }
}

#pragma mark - Player and source

- (void)_tryUpdateDataStatus:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject
{
  if (_data) {
    if ([_statusToSet count] > 0) {
      NSMutableDictionary *newStatus = [NSMutableDictionary dictionaryWithDictionary:_statusToSet];
      [_statusToSet removeAllObjects];
      [_data setStatus:newStatus resolver:resolve rejecter:reject];
    } else if (resolve) {
      resolve([_data getStatus]);
    }
  } else if (resolve) {
    resolve([EXAVPlayerData getUnloadedStatus]);
  }
}

- (void)_updateForNewPlayer
{
  [self setPlayerHasLoaded:YES];
  [self _updateNativeResizeMode];
  [self setUseNativeControls:_useNativeControls];
  if (_onLoad) {
    _onLoad([self getStatus]);
  }
  if (_requestedFullscreenChangeResolver || _requestedFullscreenChangeRejecter) {
    [self setFullscreen:_requestedFullscreenChange resolver:_requestedFullscreenChangeResolver rejecter:_requestedFullscreenChangeRejecter];
    _requestedFullscreenChangeResolver = nil;
    _requestedFullscreenChangeRejecter = nil;
    _requestedFullscreenChange = NO;
  }
}

- (void)_removePlayer
{
  if (_requestedFullscreenChangeRejecter) {
    NSString *errorMessage = @"Player is being removed, cancelling fullscreen change request.";
    _requestedFullscreenChangeRejecter(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    _requestedFullscreenChangeResolver = nil;
    _requestedFullscreenChangeRejecter = nil;
    _requestedFullscreenChange = NO;
  }

  if (_data) {
    [_data pauseImmediately];
    [_data setStatusUpdateCallback:nil];
    [_exAV demoteAudioSessionIfPossible];
    [self _removeFullscreenPlayerViewController];
    [self _removePlayerLayer];
    [self _removePlayerViewController];
    _data = nil;
  }
}

#pragma mark - _playerViewController / _playerLayer management

- (EXVideoPlayerViewController *)_createNewPlayerViewController
{
  if (_data == nil) {
    return nil;
  }
  EXVideoPlayerViewController *controller = [[EXVideoPlayerViewController alloc] init];
  [controller setShowsPlaybackControls:_useNativeControls];
  [controller setRctDelegate:self];
  [controller.view setFrame:self.bounds];
  [controller setPlayer:_data.player];
  [controller addObserver:self forKeyPath:EXVideoReadyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
  return controller;
}

- (void)_usePlayerLayer
{
  if (_data) {
    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_data.player];
    [_playerLayer setFrame:self.bounds];
    [_playerLayer setNeedsDisplayOnBoundsChange:YES];
    [_playerLayer addObserver:self forKeyPath:EXVideoReadyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
    
    // Resize mode must be set before layer is added
    // to prevent video from being animated when `resizeMode` is `cover`
    [self _updateNativeResizeMode];
    
    [self.layer addSublayer:_playerLayer];
    [self.layer setNeedsDisplayOnBoundsChange:YES];
  }
}

- (void)_removePlayerLayer
{
  if (_playerLayer) {
    [_playerLayer removeFromSuperlayer];
    [_playerLayer removeObserver:self forKeyPath:EXVideoReadyForDisplayKeyPath];
    _playerLayer = nil;
  }
}

- (void)_removeFullscreenPlayerViewController
{
  if (_fullscreenPlayerViewController) {
    [_fullscreenPlayerViewController removeObserver:self forKeyPath:EXVideoReadyForDisplayKeyPath];
    _fullscreenPlayerViewController = nil;
  }
}

- (void)_removePlayerViewController
{
  if (_playerViewController) {
    [_playerViewController.view removeFromSuperview];
    [_playerViewController removeObserver:self forKeyPath:EXVideoReadyForDisplayKeyPath];
    _playerViewController = nil;
  }
}


#pragma mark - Observers

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
  if ((object == _playerLayer || object == _playerViewController || object == _fullscreenPlayerViewController) && [keyPath isEqualToString:EXVideoReadyForDisplayKeyPath]) {
    if ([change objectForKey:NSKeyValueChangeNewKey] && _onReadyForDisplay) {
      // Calculate natural size of video:
      NSDictionary *naturalSize;
      
      if ([_data.player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo].count > 0) {
        AVAssetTrack *videoTrack = [[_data.player.currentItem.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
        CGFloat width = videoTrack.naturalSize.width;
        CGFloat height = videoTrack.naturalSize.height;
        CGAffineTransform preferredTransform = [videoTrack preferredTransform];
        CGFloat tx = preferredTransform.tx;
        CGFloat ty = preferredTransform.ty;
        
        naturalSize = @{@"width": @(width),
                        @"height": @(height),
                        @"orientation": ((width == tx && height == ty) || (tx == 0 && ty == 0)) ? @"landscape" : @"portrait"};
      } else {
        naturalSize = nil;
      }
      
      if (naturalSize) {
        _onReadyForDisplay(@{@"naturalSize": naturalSize,
                             @"status": [_data getStatus]});
      }
    }
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

#pragma mark - Imperative API

- (void)setUri:(NSString *)uri
    withStatus:(NSDictionary *)initialStatus
      resolver:(RCTPromiseResolveBlock)resolve
      rejecter:(RCTPromiseRejectBlock)reject
{
  if (_data) {
    [_statusToSet addEntriesFromDictionary:[_data getStatus]];
    [self _removePlayer];
  }
  
  if (initialStatus) {
    [_statusToSet addEntriesFromDictionary:initialStatus];
  }
  
  if (uri == nil) {
    if (resolve) {
      resolve([EXAVPlayerData getUnloadedStatus]);
    }
    return;
  }
  
  NSMutableDictionary *statusToInitiallySet = [NSMutableDictionary dictionaryWithDictionary:_statusToSet];
  [_statusToSet removeAllObjects];
  
  __weak EXVideoView *weakSelf = self;
  
  void (^statusUpdateCallback)(NSDictionary *) = ^(NSDictionary *status) {
    __strong EXVideoView *strongSelf = weakSelf;
    if (strongSelf && strongSelf.onStatusUpdate) {
      strongSelf.onStatusUpdate(status);
    }
  };
  
  void (^errorCallback)(NSString *) = ^(NSString *error) {
    __strong EXVideoView *strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf _removePlayer];
      [strongSelf _callErrorCallback:error];
    }
  };
  
  _data = [[EXAVPlayerData alloc] initWithEXAV:_exAV
                                       withURL:[NSURL URLWithString:uri]
                                    withStatus:statusToInitiallySet
                           withLoadFinishBlock:^(BOOL success, NSDictionary *successStatus, NSString *error) {
                             __strong EXVideoView *strongSelf = weakSelf;
                             if (strongSelf && success) {
                               [strongSelf _updateForNewPlayer];
                               if (resolve) {
                                 resolve(successStatus);
                               }
                             } else if (strongSelf) {
                               [strongSelf _removePlayer];
                               if (reject) {
                                 reject(@"E_VIDEO_NOTCREATED", error, RCTErrorWithMessage(error));
                               }
                               [strongSelf _callErrorCallback:error];
                             }
                           }];
  [_data setStatusUpdateCallback:statusUpdateCallback];
  [_data setErrorCallback:errorCallback];
  
  // Call onLoadStart on next run loop, otherwise it might not be set yet (if it is set at the same time as uri, via props)
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) 0), dispatch_get_main_queue(), ^{
    __strong EXVideoView *strongSelf = weakSelf;
    if (strongSelf && strongSelf.onLoadStart) {
      strongSelf.onLoadStart(nil);
    }
  });
}

- (void)setStatus:(NSDictionary *)status
         resolver:(RCTPromiseResolveBlock)resolve
         rejecter:(RCTPromiseRejectBlock)reject
{
  if (status != nil) {
    [_statusToSet addEntriesFromDictionary:status];
  }
  [self _tryUpdateDataStatus:resolve rejecter:reject];
}

- (void)replayWithStatus:(NSDictionary *)status
                resolver:(RCTPromiseResolveBlock)resolve
                rejecter:(RCTPromiseRejectBlock)reject
{
  if (status != nil) {
    [_statusToSet addEntriesFromDictionary:status];
  }
  
  NSMutableDictionary *newStatus = [NSMutableDictionary dictionaryWithDictionary:_statusToSet];
  [_statusToSet removeAllObjects];
  
  [_data replayWithStatus:newStatus resolver:resolve rejecter:reject];
}

- (void)setFullscreen:(BOOL)value
             resolver:(RCTPromiseResolveBlock)resolve
             rejecter:(RCTPromiseRejectBlock)reject
{
  if (!_data) {
    // Tried to set fullscreen for an unloaded component.
    if (reject) {
      NSString *errorMessage = @"Fullscreen encountered an error: video is not loaded.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    }
    return;
  } else if (!_playerHasLoaded) {
    // `setUri` has been called, but the video has not yet loaded.
    if (_requestedFullscreenChangeRejecter) {
      NSString *errorMessage = @"Received newer request, cancelling fullscreen mode change request.";
      _requestedFullscreenChangeRejecter(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    }
    
    _requestedFullscreenChange = value;
    _requestedFullscreenChangeRejecter = reject;
    _requestedFullscreenChangeResolver = resolve;
    return;
  } else {
    __weak EXVideoView *weakSelf = self;
    if (value && !_fullscreenPlayerPresented && !_fullscreenPlayerViewController) {
      _fullscreenPlayerViewController = [self _createNewPlayerViewController];

      // Resize mode must be set before layer is added
      // to prevent video from being animated when `resizeMode` is `cover`
      [self _updateNativeResizeMode];

      // Set presentation style to fullscreen
      [_fullscreenPlayerViewController setModalPresentationStyle:UIModalPresentationFullScreen];

      // Find the nearest view controller
      _presentingViewController = RCTPresentedViewController();
      [self _callFullscreenCallbackForUpdate:EXVideoFullscreenUpdatePlayerWillPresent];

      dispatch_async(dispatch_get_main_queue(), ^{
        __strong EXVideoView *strongSelf = weakSelf;
        if (strongSelf) {
          strongSelf.fullscreenPlayerViewController.showsPlaybackControls = YES;
          [strongSelf.presentingViewController presentViewController:strongSelf.fullscreenPlayerViewController animated:YES completion:^{
            __strong EXVideoView *strongSelfInner = weakSelf;
            if (strongSelfInner) {
              strongSelfInner.fullscreenPlayerPresented = YES;
              [strongSelfInner _callFullscreenCallbackForUpdate:EXVideoFullscreenUpdatePlayerDidPresent];
              if (resolve) {
                resolve([strongSelfInner getStatus]);
              }
            }
          }];
        }
      });
    } else if (!value && _fullscreenPlayerPresented && !_fullscreenPlayerIsDismissing) {
      [self videoPlayerViewControllerWillDismiss:_fullscreenPlayerViewController];

      dispatch_async(dispatch_get_main_queue(), ^{
        __strong EXVideoView *strongSelf = weakSelf;
        if (strongSelf) {
          [strongSelf.presentingViewController dismissViewControllerAnimated:YES completion:^{
            __strong EXVideoView *strongSelfInner = weakSelf;
            if (strongSelfInner) {
              [strongSelfInner videoPlayerViewControllerDidDismiss:strongSelfInner.fullscreenPlayerViewController];
              if (resolve) {
                resolve([strongSelfInner getStatus]);
              }
            }
          }];
        }
      });
    } else if (value && !_fullscreenPlayerPresented && _fullscreenPlayerViewController && reject) {
      // Fullscreen player should be presented, is being presented, but hasn't been presented yet.
      NSString *errorMessage = @"Fullscreen player is already being presented. Await the first change request.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    } else if (!value && _fullscreenPlayerIsDismissing && _fullscreenPlayerViewController && reject) {
      // Fullscreen player should be dismissing, is already dismissing, but hasn't dismissed yet.
      NSString *errorMessage = @"Fullscreen player is already being dismissed. Await the first change request.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    } else if (!value && !_fullscreenPlayerPresented && _fullscreenPlayerViewController && reject) {
      // Fullscreen player is being presented and we receive request to dismiss it.
      NSString *errorMessage = @"Fullscreen player is being presented. Await the `present` request and then dismiss the player.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    } else if (value && _fullscreenPlayerIsDismissing && _fullscreenPlayerViewController && reject) {
      // Fullscreen player is being dismissed and we receive request to present it.
      NSString *errorMessage = @"Fullscreen player is being dismissed. Await the `dismiss` request and then present the player again.";
      reject(@"E_VIDEO_FULLSCREEN", errorMessage, RCTErrorWithMessage(errorMessage));
    } else if (resolve) {
       // Fullscreen is already appropriately set.
      resolve([self getStatus]);
    }
  }
}

#pragma mark - Prop setters

- (void)setUri:(NSString *)uri
{
  [self setUri:uri withStatus:nil resolver:nil rejecter:nil];
}

- (NSString *)getUri
{
  return _data != nil ? _data.url.absoluteString : @"";
}

- (void)setUseNativeControls:(BOOL)useNativeControls
{
  _useNativeControls = useNativeControls;
  if (_data == nil) {
    return;
  }
  
  __weak EXVideoView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong EXVideoView *strongSelf = weakSelf;
    if (strongSelf && strongSelf.useNativeControls) {
      if (strongSelf.playerLayer) {
        [strongSelf _removePlayerLayer];
      }
      if (!strongSelf.playerViewController && strongSelf.data) {
        strongSelf.playerViewController = [strongSelf _createNewPlayerViewController];
        // Resize mode must be set before layer is added
        // to prevent video from being animated when `resizeMode` is `cover`
        [strongSelf _updateNativeResizeMode];
        [strongSelf addSubview:strongSelf.playerViewController.view];
      }
    } else if (strongSelf) {
      if (strongSelf.playerViewController) {
        [strongSelf _removePlayerViewController];
      }
      if (!strongSelf.playerLayer) {
        [strongSelf _usePlayerLayer];
      }
    }
  });
}

- (void)setNativeResizeMode:(NSString*)mode
{
  _nativeResizeMode = mode;
  [self _updateNativeResizeMode];
}

- (void)_updateNativeResizeMode
{
  if (_useNativeControls) {
    if (_playerViewController) {
      [_playerViewController setVideoGravity:_nativeResizeMode];
    }
    if (_fullscreenPlayerViewController) {
      [_fullscreenPlayerViewController setVideoGravity:_nativeResizeMode];
    }
  } else if (_playerLayer) {
    [_playerLayer setVideoGravity:_nativeResizeMode];
  }
}

- (void)setStatus:(NSDictionary *)status
{
  [self setStatus:status resolver:nil rejecter:nil];
}

- (NSDictionary *)getStatus
{
  if (_data) {
    return [_data getStatus];
  } else {
    return [EXAVPlayerData getUnloadedStatus];
  }
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
  // We are early in the game and somebody wants to set a subview.
  // That can only be in the context of playerViewController.
  if (!_useNativeControls && !_playerLayer && !_playerViewController) {
    [self setUseNativeControls:YES];
  }
  
  if (_useNativeControls && _playerViewController) {
    [super insertReactSubview:view atIndex:atIndex];
    [view setFrame:self.bounds];
    [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
  } else {
    RCTLogError(@"video cannot have any subviews");
  }
}

- (void)removeReactSubview:(UIView *)subview
{
  if (_useNativeControls) {
    [super removeReactSubview:subview];
    [subview removeFromSuperview];
  } else {
    RCTLogError(@"video cannot have any subviews");
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (_useNativeControls && _playerViewController) {
    [_playerViewController.view setFrame:self.bounds];
    
    // also adjust all subviews of contentOverlayView
    for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
      [subview setFrame:self.bounds];
    }
  } else if (!_useNativeControls && _playerLayer) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:0];
    [_playerLayer setFrame:self.bounds];
    [CATransaction commit];
  }
}

- (void)removeFromSuperview
{
  [self _removePlayer];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [super removeFromSuperview];
}

#pragma mark - EXVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
  if (_fullscreenPlayerViewController == playerViewController && _fullscreenPlayerPresented) {
    _fullscreenPlayerIsDismissing = YES;
    [self _callFullscreenCallbackForUpdate:EXVideoFullscreenUpdatePlayerWillDismiss];
  }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
  if (_fullscreenPlayerViewController == playerViewController && _fullscreenPlayerPresented) {
    _fullscreenPlayerIsDismissing = NO;
    _fullscreenPlayerPresented = NO;
    _presentingViewController = nil;
    [self _removeFullscreenPlayerViewController];
    [self setUseNativeControls:_useNativeControls];
    [self _callFullscreenCallbackForUpdate:EXVideoFullscreenUpdatePlayerDidDismiss];
  }
}

#pragma mark - EXAVObject

- (void)pauseImmediately
{
  if (_data) {
    [_data pauseImmediately];
  }
}

- (EXAVAudioSessionMode)getAudioSessionModeRequired
{
  return _data == nil ? EXAVAudioSessionModeInactive : [_data getAudioSessionModeRequired];
}

- (void)bridgeDidForeground:(NSNotification *)notification
{
  if (_data) {
    [_data bridgeDidForeground:notification];
  }
}

- (void)bridgeDidBackground:(NSNotification *)notification
{
  if (_data) {
    [_data bridgeDidForeground:notification];
  }
}

- (void)handleAudioSessionInterruption:(NSNotification*)notification
{
  if (_data) {
    [_data handleAudioSessionInterruption:notification];
  }
}

- (void)handleMediaServicesReset:(void (^)(void))finishCallback
{
  if (_data) {
    if (_onLoadStart) {
      _onLoadStart(nil);
    }
    [self _removePlayerLayer];
    [self _removePlayerViewController];
    
    __weak __typeof__(self) weakSelf = self;
    [_data handleMediaServicesReset:^{
      __strong EXVideoView *strongSelf = weakSelf;
      if (strongSelf) {
        [strongSelf _updateForNewPlayer];
      }
      if (finishCallback != nil) {
        finishCallback();
      }
    }];
  }
}

#pragma mark - NSObject Lifecycle

- (void)dealloc
{
  [_exAV unregisterVideoForAudioLifecycle:self];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_data pauseImmediately];
  [_exAV demoteAudioSessionIfPossible];
}

@end
