#import <Foundation/Foundation.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
// The remote host can return nil during teardown despite UIKit's nonnull
// annotation. Preserve that value before Swift bridges NSUUID to UUID.
static inline NSUUID * _Nullable RimeDocumentIdentifier(id<UITextDocumentProxy> _Nullable proxy) {
    return proxy.documentIdentifier;
}
#endif

NS_ASSUME_NONNULL_BEGIN
@interface RimeSnapshot : NSObject
@property(nonatomic, readonly) NSString *input;
@property(nonatomic, readonly) NSString *preedit;
@property(nonatomic, readonly) NSArray<NSString *> *candidates;
@property(nonatomic, readonly, nullable) NSString *fullInputCandidate;
@property(nonatomic, readonly) NSString *commit;
@end

@interface RimeEngine : NSObject
+ (nullable NSString *)validateLua:(NSString *)source name:(NSString *)name NS_SWIFT_NAME(validateLua(_:name:));
+ (nullable NSString *)validateLua:(NSString *)source name:(NSString *)name bundle:(NSBundle *)bundle NS_SWIFT_NAME(validateLua(_:name:bundle:));
- (nullable instancetype)initWithShared:(NSString *)shared user:(NSString *)user;
- (BOOL)openSession:(NSString *)schema;
// Use on a scratch engine during profile compilation. Opens each schema in turn.
- (NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSString *> *> *> *)firstKeyCandidateRows;
- (void)setTraditional:(BOOL)traditional;
- (void)closePreview;
- (void)close;
@property(nonatomic, readonly) NSDictionary<NSString *, NSString *> *schemas;
@property(nonatomic, readonly) NSString *input;
@property(nonatomic, readonly) NSString *preedit;
@property(nonatomic, readonly) NSArray<NSString *> *candidates;
@property(nonatomic, readonly, nullable) NSString *fullInputCandidate;
- (RimeSnapshot *)snapshotWithCandidateLimit:(NSUInteger)limit NS_SWIFT_NAME(snapshot(candidateLimit:));
- (NSArray<NSString *> *)previewCandidatesForInput:(NSString *)input NS_SWIFT_NAME(previewCandidates(for:));
// The first candidate only when it covers the entire spelling in the preview session.
- (nullable NSString *)previewFullInputCandidateForInput:(NSString *)input NS_SWIFT_NAME(previewFullInputCandidate(for:));
// Read the spelling of this specific candidate without changing the live composition.
- (nullable NSString *)previewReadingForInput:(NSString *)input title:(NSString *)title index:(NSInteger)index
    NS_SWIFT_NAME(previewReading(for:title:index:));
// Highlight each native index in the preview session and return complete readings.
- (NSDictionary<NSNumber *, NSString *> *)previewCompleteCandidatesForInput:(NSString *)input
                                                                   indexes:(NSArray<NSNumber *> *)indexes
    NS_SWIFT_NAME(previewCompleteCandidates(for:indexes:));
- (NSArray<NSString *> *)previewCandidatesForInput:(NSString *)input limit:(NSUInteger)limit NS_SWIFT_NAME(previewCandidates(for:limit:));
- (NSArray<NSString *> *)candidatesFromIndex:(NSUInteger)start limit:(NSUInteger)limit NS_SWIFT_NAME(candidates(from:limit:));
- (NSArray<NSString *> *)previewCandidatesForInput:(NSString *)input start:(NSUInteger)start limit:(NSUInteger)limit NS_SWIFT_NAME(previewCandidates(for:from:limit:));
- (BOOL)key:(int)code;
- (BOOL)select:(NSUInteger)index;
- (void)setLearningEnabled:(BOOL)enabled;
- (NSString *)takeCommit;
- (void)clear;
- (BOOL)replaceInput:(NSString *)input;
- (BOOL)sync;
- (BOOL)deploy;
@end
NS_ASSUME_NONNULL_END
