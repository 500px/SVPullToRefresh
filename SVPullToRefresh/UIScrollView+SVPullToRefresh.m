//
// UIScrollView+SVPullToRefresh.m
//
// Created by Sam Vermette on 23.04.12.
// Copyright (c) 2012 samvermette.com. All rights reserved.
//
// https://github.com/samvermette/SVPullToRefresh
//

#import <QuartzCore/QuartzCore.h>
#import "UIScrollView+SVPullToRefresh.h"

//fequal() and fequalzro() from http://stackoverflow.com/a/1614761/184130
#define fequal(a,b) (fabs((a) - (b)) < FLT_EPSILON)
#define fequalzero(a) (fabs(a) < FLT_EPSILON)

static CGFloat const SVPullToRefreshViewHeight = 60;

@interface SVPullToRefreshView ()

@property (nonatomic, copy) void (^pullToRefreshActionHandler)(void);

@property (nonatomic, strong) UIImageView *arrow;
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicatorView;
@property (nonatomic, readwrite) SVPullToRefreshState state;
@property (nonatomic, readwrite) SVPullToRefreshPosition position;

@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, readwrite) CGFloat originalTopInset;
@property (nonatomic, readwrite) CGFloat originalBottomInset;

@property (nonatomic, assign) BOOL wasTriggeredByUser;
@property (nonatomic, assign) BOOL showsPullToRefresh;
@property(nonatomic, assign) BOOL isObserving;

- (void)resetScrollViewContentInset;
- (void)setScrollViewContentInsetForLoading;
- (void)setScrollViewContentInset:(UIEdgeInsets)insets;
- (void)rotateArrow:(float)degrees hide:(BOOL)hide;

@end



#pragma mark - UIScrollView (SVPullToRefresh)
#import <objc/runtime.h>

static char UIScrollViewPullToRefreshView;

@implementation UIScrollView (SVPullToRefresh)

@dynamic pullToRefreshView, showsPullToRefresh;

- (void)addPullToRefreshWithActionHandler:(void (^)(void))actionHandler position:(SVPullToRefreshPosition)position {
    
    if(!self.pullToRefreshView) {
        CGFloat yOrigin;
        switch (position) {
            case SVPullToRefreshPositionTop:
                yOrigin = -SVPullToRefreshViewHeight;
                break;
            case SVPullToRefreshPositionBottom:
                yOrigin = self.contentSize.height;
                break;
            default:
                return;
        }
        SVPullToRefreshView *view = [[SVPullToRefreshView alloc] initWithFrame:CGRectMake(0, yOrigin, self.bounds.size.width, SVPullToRefreshViewHeight)];
        view.pullToRefreshActionHandler = actionHandler;
        view.scrollView = self;
        [self addSubview:view];
        
        view.originalTopInset = self.contentInset.top;
        view.originalBottomInset = self.contentInset.bottom;
        view.position = position;
        self.pullToRefreshView = view;
        self.showsPullToRefresh = YES;
    }
    
}

- (void)addPullToRefreshWithActionHandler:(void (^)(void))actionHandler {
    [self addPullToRefreshWithActionHandler:actionHandler position:SVPullToRefreshPositionTop];
}

- (void)triggerPullToRefresh {
    self.pullToRefreshView.state = SVPullToRefreshStateTriggered;
    [self.pullToRefreshView startAnimating];
}

- (void)setPullToRefreshView:(SVPullToRefreshView *)pullToRefreshView {
    [self willChangeValueForKey:@"SVPullToRefreshView"];
    objc_setAssociatedObject(self, &UIScrollViewPullToRefreshView,
                             pullToRefreshView,
                             OBJC_ASSOCIATION_ASSIGN);
    [self didChangeValueForKey:@"SVPullToRefreshView"];
}

- (SVPullToRefreshView *)pullToRefreshView {
    return objc_getAssociatedObject(self, &UIScrollViewPullToRefreshView);
}

- (void)setShowsPullToRefresh:(BOOL)showsPullToRefresh {
    self.pullToRefreshView.hidden = !showsPullToRefresh;
    
    if(!showsPullToRefresh) {
        if (self.pullToRefreshView.isObserving) {
            [self removeObserver:self.pullToRefreshView forKeyPath:@"contentOffset"];
            [self removeObserver:self.pullToRefreshView forKeyPath:@"contentSize"];
            [self removeObserver:self.pullToRefreshView forKeyPath:@"frame"];
            [self.pullToRefreshView resetScrollViewContentInset];
            self.pullToRefreshView.isObserving = NO;
        }
    }
    else {
        if (!self.pullToRefreshView.isObserving) {
            [self addObserver:self.pullToRefreshView forKeyPath:@"contentOffset" options:NSKeyValueObservingOptionNew context:nil];
            [self addObserver:self.pullToRefreshView forKeyPath:@"contentSize" options:NSKeyValueObservingOptionNew context:nil];
            [self addObserver:self.pullToRefreshView forKeyPath:@"frame" options:NSKeyValueObservingOptionNew context:nil];
            self.pullToRefreshView.isObserving = YES;
            
            CGFloat yOrigin = 0;
            switch (self.pullToRefreshView.position) {
                case SVPullToRefreshPositionTop:
                    yOrigin = -SVPullToRefreshViewHeight;
                    break;
                case SVPullToRefreshPositionBottom:
                    yOrigin = self.contentSize.height;
                    break;
            }
            
            self.pullToRefreshView.frame = CGRectMake(0, yOrigin, self.bounds.size.width, SVPullToRefreshViewHeight);
        }
    }
}

- (BOOL)showsPullToRefresh {
    return !self.pullToRefreshView.hidden;
}

@end

#pragma mark - SVPullToRefresh
@implementation SVPullToRefreshView

// public properties
@synthesize pullToRefreshActionHandler, activityIndicatorViewColor, activityIndicatorViewStyle;

@synthesize state = _state;
@synthesize scrollView = _scrollView;
@synthesize showsPullToRefresh = _showsPullToRefresh;
@synthesize arrow = _arrow;
@synthesize activityIndicatorView = _activityIndicatorView;

- (id)initWithFrame:(CGRect)frame {
    if(self = [super initWithFrame:frame]) {
        
        // default styling values
        self.activityIndicatorViewStyle = UIActivityIndicatorViewStyleGray;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.state = SVPullToRefreshStateStopped;
        self.wasTriggeredByUser = YES;
    }
    
    return self;
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (self.superview && newSuperview == nil) {
        //use self.superview, not self.scrollView. Why self.scrollView == nil here?
        UIScrollView *scrollView = (UIScrollView *)self.superview;
        if (scrollView.showsPullToRefresh) {
            if (self.isObserving) {
                //If enter this branch, it is the moment just before "SVPullToRefreshView's dealloc", so remove observer here
                [scrollView removeObserver:self forKeyPath:@"contentOffset"];
                [scrollView removeObserver:self forKeyPath:@"contentSize"];
                [scrollView removeObserver:self forKeyPath:@"frame"];
                self.isObserving = NO;
            }
        }
    }
}

- (void)layoutSubviews {
    
    switch (self.state) {
        case SVPullToRefreshStateAll:
        case SVPullToRefreshStateStopped:
            self.arrow.alpha = 1;
            [self.activityIndicatorView stopAnimating];
            switch (self.position) {
                case SVPullToRefreshPositionTop:
                    [self rotateArrow:0 hide:NO];
                    break;
                case SVPullToRefreshPositionBottom:
                    [self rotateArrow:(float)M_PI hide:NO];
                    break;
            }
            break;
            
        case SVPullToRefreshStateTriggered:
            switch (self.position) {
                case SVPullToRefreshPositionTop:
                    [self rotateArrow:(float)M_PI hide:NO];
                    break;
                case SVPullToRefreshPositionBottom:
                    [self rotateArrow:0 hide:NO];
                    break;
            }
            break;
            
        case SVPullToRefreshStateLoading:
            [self.activityIndicatorView startAnimating];
            switch (self.position) {
                case SVPullToRefreshPositionTop:
                    [self rotateArrow:0 hide:YES];
                    break;
                case SVPullToRefreshPositionBottom:
                    [self rotateArrow:(float)M_PI hide:YES];
                    break;
            }
            break;
    }
    
    CGFloat leftViewWidth = MAX(self.arrow.bounds.size.width,self.activityIndicatorView.bounds.size.width);
    
    CGFloat totalMaxWidth = leftViewWidth;
    CGFloat arrowX = (self.bounds.size.width / 2) - (totalMaxWidth / 2) + (leftViewWidth - self.arrow.bounds.size.width) / 2;
    self.arrow.frame = CGRectMake(arrowX,
                                  (self.bounds.size.height / 2) - (self.arrow.bounds.size.height / 2),
                                  self.arrow.bounds.size.width,
                                  self.arrow.bounds.size.height);
    self.activityIndicatorView.center = self.arrow.center;
}

#pragma mark - Scroll View

- (void)resetScrollViewContentInset {
    UIEdgeInsets currentInsets = self.scrollView.contentInset;
    switch (self.position) {
        case SVPullToRefreshPositionTop:
            currentInsets.top = self.originalTopInset;
            break;
        case SVPullToRefreshPositionBottom:
            currentInsets.bottom = self.originalBottomInset;
            currentInsets.top = self.originalTopInset;
            break;
    }
    [self setScrollViewContentInset:currentInsets];
}

- (void)setScrollViewContentInsetForLoading {
    CGFloat offset = MAX(self.scrollView.contentOffset.y * -1, 0);
    UIEdgeInsets currentInsets = self.scrollView.contentInset;
    switch (self.position) {
        case SVPullToRefreshPositionTop:
            currentInsets.top = MIN(offset, self.originalTopInset + self.bounds.size.height);
            break;
        case SVPullToRefreshPositionBottom:
            currentInsets.bottom = MIN(offset, self.originalBottomInset + self.bounds.size.height);
            break;
    }
    [self setScrollViewContentInset:currentInsets];
}

- (void)setScrollViewContentInset:(UIEdgeInsets)contentInset {
    [UIView animateWithDuration:0.3
                          delay:0
                        options:UIViewAnimationOptionAllowUserInteraction|UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         self.scrollView.contentInset = contentInset;
                     }
                     completion:NULL];
}

#pragma mark - Observing

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if([keyPath isEqualToString:@"contentOffset"])
        [self scrollViewDidScroll:[[change valueForKey:NSKeyValueChangeNewKey] CGPointValue]];
    else if([keyPath isEqualToString:@"contentSize"]) {
        [self layoutSubviews];
        
        CGFloat yOrigin;
        switch (self.position) {
            case SVPullToRefreshPositionTop:
                yOrigin = -SVPullToRefreshViewHeight;
                break;
            case SVPullToRefreshPositionBottom:
                yOrigin = MAX(self.scrollView.contentSize.height, self.scrollView.bounds.size.height);
                break;
        }
        self.frame = CGRectMake(0, yOrigin, self.bounds.size.width, SVPullToRefreshViewHeight);
    }
    else if([keyPath isEqualToString:@"frame"])
        [self layoutSubviews];

}

- (void)scrollViewDidScroll:(CGPoint)contentOffset {
    if(self.state != SVPullToRefreshStateLoading) {
        CGFloat scrollOffsetThreshold = 0;
        switch (self.position) {
            case SVPullToRefreshPositionTop:
                scrollOffsetThreshold = self.frame.origin.y - self.originalTopInset;
                break;
            case SVPullToRefreshPositionBottom:
                scrollOffsetThreshold = MAX(self.scrollView.contentSize.height - self.scrollView.bounds.size.height, 0.0f) + self.bounds.size.height + self.originalBottomInset;
                break;
        }
        
        if(!self.scrollView.isDragging && self.state == SVPullToRefreshStateTriggered)
            self.state = SVPullToRefreshStateLoading;
        else if(contentOffset.y < scrollOffsetThreshold && self.scrollView.isDragging && self.state == SVPullToRefreshStateStopped && self.position == SVPullToRefreshPositionTop)
            self.state = SVPullToRefreshStateTriggered;
        else if(contentOffset.y >= scrollOffsetThreshold && self.state != SVPullToRefreshStateStopped && self.position == SVPullToRefreshPositionTop)
            self.state = SVPullToRefreshStateStopped;
        else if(contentOffset.y > scrollOffsetThreshold && self.scrollView.isDragging && self.state == SVPullToRefreshStateStopped && self.position == SVPullToRefreshPositionBottom)
            self.state = SVPullToRefreshStateTriggered;
        else if(contentOffset.y <= scrollOffsetThreshold && self.state != SVPullToRefreshStateStopped && self.position == SVPullToRefreshPositionBottom)
            self.state = SVPullToRefreshStateStopped;
    } else {
        CGFloat offset;
        UIEdgeInsets contentInset;
        switch (self.position) {
            case SVPullToRefreshPositionTop:
                offset = MAX(self.scrollView.contentOffset.y * -1, 0.0f);
                offset = MIN(offset, self.originalTopInset + self.bounds.size.height);
                contentInset = self.scrollView.contentInset;
                self.scrollView.contentInset = UIEdgeInsetsMake(offset, contentInset.left, contentInset.bottom, contentInset.right);
                break;
            case SVPullToRefreshPositionBottom:
                if (self.scrollView.contentSize.height >= self.scrollView.bounds.size.height) {
                    offset = MAX(self.scrollView.contentSize.height - self.scrollView.bounds.size.height + self.bounds.size.height, 0.0f);
                    offset = MIN(offset, self.originalBottomInset + self.bounds.size.height);
                    contentInset = self.scrollView.contentInset;
                    self.scrollView.contentInset = UIEdgeInsetsMake(contentInset.top, contentInset.left, offset, contentInset.right);
                } else if (self.wasTriggeredByUser) {
                    offset = MIN(self.bounds.size.height, self.originalBottomInset + self.bounds.size.height);
                    contentInset = self.scrollView.contentInset;
                    self.scrollView.contentInset = UIEdgeInsetsMake(-offset, contentInset.left, contentInset.bottom, contentInset.right);
                }
                break;
        }
    }
}

#pragma mark - Getters

- (UIImageView *)arrow {
    if(!_arrow) {
		_arrow = [[UIImageView alloc] initWithFrame: CGRectMake(0, self.bounds.size.height - 54, 20, 21)];
        _arrow.image = [UIImage imageNamed:@"SVPullToRefresh.bundle/icon-refresh"];
        _arrow.backgroundColor = [UIColor clearColor];
		[self addSubview:_arrow];
    }
    return _arrow;
}

- (UIActivityIndicatorView *)activityIndicatorView {
    if(!_activityIndicatorView) {
        _activityIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        _activityIndicatorView.hidesWhenStopped = YES;
        [self addSubview:_activityIndicatorView];
    }
    return _activityIndicatorView;
}

- (UIColor *)activityIndicatorViewColor {
    return self.activityIndicatorView.color;
}

- (UIActivityIndicatorViewStyle)activityIndicatorViewStyle {
    return self.activityIndicatorView.activityIndicatorViewStyle;
}

#pragma mark - Setters

- (void)setActivityIndicatorViewColor:(UIColor *)color {
    self.activityIndicatorView.color = color;
}

- (void)setActivityIndicatorViewStyle:(UIActivityIndicatorViewStyle)viewStyle {
    self.activityIndicatorView.activityIndicatorViewStyle = viewStyle;
}

#pragma mark -

- (void)startAnimating{
    switch (self.position) {
        case SVPullToRefreshPositionTop:
            
            if(fequalzero(self.scrollView.contentOffset.y)) {
                [self.scrollView setContentOffset:CGPointMake(self.scrollView.contentOffset.x, -self.frame.size.height) animated:YES];
                self.wasTriggeredByUser = NO;
            }
            else
                self.wasTriggeredByUser = YES;
            
            break;
        case SVPullToRefreshPositionBottom:
            
            if((fequalzero(self.scrollView.contentOffset.y) && self.scrollView.contentSize.height < self.scrollView.bounds.size.height)
               || fequal(self.scrollView.contentOffset.y, self.scrollView.contentSize.height - self.scrollView.bounds.size.height)) {
                [self.scrollView setContentOffset:(CGPoint){.y = MAX(self.scrollView.contentSize.height - self.scrollView.bounds.size.height, 0.0f) + self.frame.size.height} animated:YES];
                self.wasTriggeredByUser = NO;
            }
            else
                self.wasTriggeredByUser = YES;
            
            break;
    }
    
    self.state = SVPullToRefreshStateLoading;
}

- (void)stopAnimating {
    self.state = SVPullToRefreshStateStopped;
    
    switch (self.position) {
        case SVPullToRefreshPositionTop:
            if(!self.wasTriggeredByUser)
                [self.scrollView setContentOffset:CGPointMake(self.scrollView.contentOffset.x, -self.originalTopInset) animated:YES];
            break;
        case SVPullToRefreshPositionBottom:
            if(!self.wasTriggeredByUser)
                [self.scrollView setContentOffset:CGPointMake(self.scrollView.contentOffset.x, self.scrollView.contentSize.height - self.scrollView.bounds.size.height + self.originalBottomInset) animated:YES];
            break;
    }
}

- (void)setState:(SVPullToRefreshState)newState {
    
    if(_state == newState)
        return;
    
    SVPullToRefreshState previousState = _state;
    _state = newState;
    
    [self setNeedsLayout];
    [self layoutIfNeeded];
    
    switch (newState) {
        case SVPullToRefreshStateAll:
        case SVPullToRefreshStateStopped:
            [self resetScrollViewContentInset];
            break;
            
        case SVPullToRefreshStateTriggered:
            break;
            
        case SVPullToRefreshStateLoading:
            [self setScrollViewContentInsetForLoading];
            
            if(previousState == SVPullToRefreshStateTriggered && pullToRefreshActionHandler)
                pullToRefreshActionHandler();
            
            break;
    }
}

- (void)rotateArrow:(float)degrees hide:(BOOL)hide {
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.arrow.layer.transform = CATransform3DMakeRotation(degrees, 0, 0, 1);
        self.arrow.layer.opacity = !hide;
    } completion:NULL];
}

@end
