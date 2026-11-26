#import "RimeEngine.h"
#import <RimeDynamic/rime_api.h>
#import <RimeDynamic/rime_levers_api.h>
#import <sys/file.h>
#import <unistd.h>
#import <dlfcn.h>

static BOOL processInUse = NO;

@implementation RimeSnapshot
- (instancetype)initWithInput:(NSString *)input
                      preedit:(NSString *)preedit
                   candidates:(NSArray<NSString *> *)candidates
           fullInputCandidate:(nullable NSString *)fullInputCandidate
                       commit:(NSString *)commit {
    if (!(self = [super init])) return nil;
    _input = [input copy];
    _preedit = [preedit copy];
    _candidates = [candidates copy];
    _fullInputCandidate = [fullInputCandidate copy];
    _commit = [commit copy];
    return self;
}
@end

@implementation RimeEngine {
    BOOL _ownsRuntime;
    RimeApi *_api;
    RimeSessionId _session;
    RimeSessionId _previewSession;
    BOOL _traditional;
    BOOL _learningEnabled;
    BOOL _provisionalSelection;
    NSString *_pendingCommit;
    int _lock;
    NSString *_user;
    NSString *_schema;
    NSString *_outputTransform;
}

+ (NSString *)validateLua:(NSString *)source name:(NSString *)name {
    return [self validateLua:source name:name bundle:NSBundle.mainBundle];
}

+ (NSString *)validateLua:(NSString *)source name:(NSString *)name bundle:(NSBundle *)bundle {
    void *(*create)(void) = dlsym(RTLD_DEFAULT, "luaL_newstate");
    int (*load)(void *, const char *, size_t, const char *, const char *) = dlsym(RTLD_DEFAULT, "luaL_loadbufferx");
    const char *(*message)(void *, int, size_t *) = dlsym(RTLD_DEFAULT, "lua_tolstring");
    void (*destroy)(void *) = dlsym(RTLD_DEFAULT, "lua_close");
    if (!create || !load || !message || !destroy) return [bundle localizedStringForKey:@"luaUnavailable" value:@"Lua validation is unavailable in this build." table:nil];
    void *state = create();
    if (!state) return [bundle localizedStringForKey:@"luaAllocationFailed" value:@"Cannot allocate the Lua validator." table:nil];
    NSData *data = [source dataUsingEncoding:NSUTF8StringEncoding];
    int status = load(state, data.bytes, data.length, name.UTF8String, "t");
    NSString *error = nil;
    if (status) {
        const char *detail = message(state, -1, NULL);
        error = detail ? @(detail) : [bundle localizedStringForKey:@"luaSyntaxError" value:@"Invalid Lua syntax." table:nil];
    }
    destroy(state);
    return error;
}
- (instancetype)initWithShared:(NSString *)shared user:(NSString *)user {
    if (!(self = [super init])) return nil;
    _lock = -1;
    if (![NSFileManager.defaultManager createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    NSString *lockPath = [user stringByAppendingPathComponent:@"engine.lock"];
    _lock = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
    if (_lock < 0 || flock(_lock, LOCK_EX | LOCK_NB) != 0) return nil;
    // librime is process-global, including when two profiles use different
    // scratch directories. Don't let an overlapping deployment finalize it.
    @synchronized (RimeEngine.class) {
        if (processInUse) return nil;
        processInUse = YES;
        _ownsRuntime = YES;
    }
    NSFileManager *fs = NSFileManager.defaultManager;
    // Wanxiang stores its Lua databases beneath the writable build directory.
    if (![fs createDirectoryAtPath:[user stringByAppendingPathComponent:@"build"] withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    // Third-party Lua translators ask for user_data_dir when opening tables.
    // Expose the profile's resource directories there without replacing actual
    // user data. Track our own links so switching profiles also retires them.
    NSString *index = [user stringByAppendingPathComponent:@"profile-links.plist"];
    NSArray *previous = [NSArray arrayWithContentsOfFile:index] ?: @[@"lua"];
    NSMutableSet *wanted = [NSMutableSet set];
    for (NSString *name in [fs contentsOfDirectoryAtPath:shared error:NULL]) {
        if ([name hasPrefix:@"."] || [@[@"build", @"Licenses"] containsObject:name]) continue;
        NSString *source = [shared stringByAppendingPathComponent:name];
        BOOL directory = NO;
        [fs fileExistsAtPath:source isDirectory:&directory];
        if (directory || [name isEqualToString:@"rime.lua"]) {
            [wanted addObject:name];
        }
    }
    NSMutableSet *managed = [NSMutableSet set];
    for (NSString *name in [wanted setByAddingObjectsFromArray:previous]) {
        if (![name isKindOfClass:NSString.class] || ![name isEqual:name.lastPathComponent] || [name hasPrefix:@"."]) continue;
        NSString *path = [user stringByAppendingPathComponent:name];
        NSString *source = [shared stringByAppendingPathComponent:name];
        NSString *old = [fs destinationOfSymbolicLinkAtPath:path error:NULL];
        if (old && [previous containsObject:name] && (![wanted containsObject:name] || ![source isEqual:old])) {
            if (![fs removeItemAtPath:path error:NULL]) return nil;
        }
        if (![wanted containsObject:name]) continue;
        if (![fs fileExistsAtPath:path]) {
            if (![fs createSymbolicLinkAtPath:path withDestinationPath:source error:NULL]) return nil;
            [managed addObject:name];
        } else if ([source isEqual:[fs destinationOfSymbolicLinkAtPath:path error:NULL]]) {
            [managed addObject:name];
        }
    }
    if (![[managed allObjects] writeToFile:index atomically:YES]) return nil;
    _user = [user copy];
    _api = rime_get_api();
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared.fileSystemRepresentation;
    traits.user_data_dir = user.fileSystemRepresentation;
    traits.app_name = "capy.input";
    traits.distribution_code_name = "CapyInput";
    traits.distribution_version = "1";
    traits.min_log_level = 2;
    traits.log_dir = "";
    static const char *modules[] = {"default", "levers", "lua", "octagram", NULL};
    traits.modules = modules;
    _api->setup(&traits);
    _api->initialize(&traits);
    // InstallationUpdate reads sync_dir from an existing installation. Seed
    // the identity before the first export so it never uses a relative path.
    if (![NSFileManager.defaultManager fileExistsAtPath:[user stringByAppendingPathComponent:@"installation.yaml"]]) {
        if (!_api->run_task("installation_update")) return nil;
    }
    return self;
}
- (void)closePreview {
    if (_previewSession) _api->destroy_session(_previewSession);
    _previewSession = 0;
}
- (BOOL)openSession:(NSString *)schema {
    [self closePreview];
    if (_session) _api->destroy_session(_session);
    _schema = [schema copy];
    _provisionalSelection = NO;
    _pendingCommit = @"";
    _outputTransform = nil;
    _session = _api->create_session();
    BOOL opened = _session && _api->select_schema(_session, schema.UTF8String);
    [self setLearningEnabled:NO];
    return opened;
}
- (NSDictionary *)firstKeyCandidateRows {
    NSMutableDictionary *table = [NSMutableDictionary dictionary];
    NSString *letters = @"abcdefghijklmnopqrstuvwxyz";
    for (NSString *schema in self.schemas) {
        if (![self openSession:schema]) continue;
        NSString *keys = ([schema isEqual:@"luna_pinyin_t9"] || [schema isEqual:@"wanxiang_t9"] || [schema isEqual:@"ice_t9"]) ? @"23456789" : letters;
        for (int traditional = 0; traditional <= 1; traditional++) {
            [self setTraditional:traditional];
            NSMutableDictionary *rows = [NSMutableDictionary dictionary];
            for (NSUInteger i = 0; i < keys.length; i++) {
                NSString *key = [keys substringWithRange:NSMakeRange(i, 1)];
                rows[key] = [self previewCandidatesForInput:key limit:8];
            }
            table[[schema stringByAppendingString:traditional ? @"/traditional" : @"/simplified"]] = rows;
        }
    }
    return table;
}
- (void)setTraditional:(BOOL)traditional {
    _traditional = traditional;
    [self applyTraditional:traditional session:_session];
    [self applyTraditional:traditional session:_previewSession];
}
- (void)applyTraditional:(BOOL)traditional session:(RimeSessionId)session {
    if (!session) return;
    if ([_schema isEqual:@"wanxiang"] || [_schema hasPrefix:@"wanxiang_"]) {
        _api->set_option(session, "s2hk", NO);
        _api->set_option(session, "s2tw", NO);
        _api->set_option(session, "s2s", !traditional);
        _api->set_option(session, "s2t", traditional);
        return;
    }
    if ([_schema isEqual:@"ice"] || [_schema hasPrefix:@"ice_"]) {
        _api->set_option(session, "traditionalization", traditional);
        return;
    }
    // Imported schemas can have their own script switches. Preserve their
    // options and apply the requested script to candidate and commit text.
    if (![_schema isEqual:@"double_pinyin_flypy"] && ![_schema isEqual:@"luna_pinyin_simp"]) {
        _outputTransform = traditional ? @"Simplified-Traditional" : @"Traditional-Simplified";
        return;
    }
    // Flypy uses a binary switch. Luna uses a mutually exclusive regional group.
    _api->set_option(session, "simplification", !traditional);
    _api->set_option(session, "zh_hant_hk", NO);
    _api->set_option(session, "zh_hant_tw", NO);
    _api->set_option(session, "zh_hant", traditional);
    _api->set_option(session, "zh_hans", !traditional);
}
- (NSDictionary *)schemas {
    RimeSchemaList list = {0};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (_api->get_schema_list(&list)) {
        for (size_t i = 0; i < list.size; i++)
            result[@(list.list[i].schema_id)] = @(list.list[i].name);
        _api->free_schema_list(&list);
    }
    return result;
}
- (NSString *)input {
    const char *value = _api->get_input(_session);
    return value ? @(value) : @"";
}
- (NSString *)preeditFromContext:(const RimeContext *)ctx {
    NSString *value = ctx->composition.preedit ? @(ctx->composition.preedit) : @"";
    if ([_schema isEqual:@"luna_pinyin_t9"] || [_schema isEqual:@"wanxiang_t9"] || [_schema isEqual:@"ice_t9"]) {
        // T9's preedit contains digit spellings. The translator's spelling hint
        // carries the actual dictionary reading, including ambiguous syllables.
        int index = ctx->menu.highlighted_candidate_index;
        if (index >= 0 && index < ctx->menu.num_candidates && ctx->menu.candidates[index].comment) {
            NSString *reading = [@(ctx->menu.candidates[index].comment)
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (reading.length) {
                NSString *tail = @"";
                if (ctx->composition.preedit && ctx->composition.sel_end > 0 &&
                    ctx->composition.sel_end < ctx->composition.length) {
                    tail = @(ctx->composition.preedit + ctx->composition.sel_end);
                }
                value = [reading stringByAppendingString:tail.length ? [@" " stringByAppendingString:tail] : @""];
            }
        }
        if ([_schema isEqual:@"wanxiang_t9"]) {
            // Wanxiang's dictionary spelling hints carry tone marks (and
            // optionally Lua tips). Normalize to plain Latin pinyin natively.
            if ([value containsString:@"〔"]) {
                static NSRegularExpression *tips;
                static dispatch_once_t onceToken;
                dispatch_once(&onceToken, ^{
                    tips = [NSRegularExpression regularExpressionWithPattern:@"〔[^〕]*〕" options:0 error:nil];
                });
                value = [tips stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
            }
            value = [value stringByApplyingTransform:NSStringTransformStripDiacritics reverse:NO] ?: value;
        }
        // An unresolved suffix has no chosen pronunciation yet; show its letter
        // groups rather than presenting the numeric key codes as pinyin.
        static NSArray *groups;
        static dispatch_once_t groupsOnce;
        dispatch_once(&groupsOnce, ^{
            groups = @[@"abc", @"def", @"ghi", @"jkl", @"mno", @"pqrs", @"tuv", @"wxyz"];
        });
        for (NSUInteger i = 0; i < groups.count; i++) {
            NSString *digit = [NSString stringWithFormat:@"%lu", (unsigned long)i + 2];
            if ([value containsString:digit]) {
                value = [value stringByReplacingOccurrencesOfString:digit
                    withString:[NSString stringWithFormat:@"[%@]", groups[i]]];
            }
        }
    }
    return value;
}
- (NSString *)preedit {
    RIME_STRUCT(RimeContext, ctx);
    if (!_api->get_context(_session, &ctx)) return @"";
    NSString *value = [self preeditFromContext:&ctx];
    _api->free_context(&ctx);
    return value;
}
- (NSString *)outputText:(NSString *)text {
    if (!_outputTransform) return text;
    return [text stringByApplyingTransform:_outputTransform reverse:NO] ?: text;
}
- (NSArray *)candidates {
    return [self candidatesFromIndex:0 limit:32];
}
- (nullable NSString *)fullInputCandidateFromContext:(const RimeContext *)ctx rawInput:(const char *)input session:(RimeSessionId)session {
    if (input && *input && _api->get_caret_pos(session) == strlen(input) &&
        ctx->menu.page_no == 0 && ctx->menu.highlighted_candidate_index == 0 && ctx->menu.num_candidates > 0 &&
        ctx->composition.sel_start == 0 && ctx->composition.sel_end == ctx->composition.length &&
        ctx->composition.cursor_pos == ctx->composition.length) {
        return [self outputText:@(ctx->menu.candidates[0].text)];
    }
    return nil;
}
- (NSString *)fullInputCandidate {
    RIME_STRUCT(RimeContext, ctx);
    if (!_api->get_context(_session, &ctx)) return nil;
    NSString *text = [self fullInputCandidateFromContext:&ctx rawInput:_api->get_input(_session) session:_session];
    _api->free_context(&ctx);
    return text;
}
- (RimeSnapshot *)snapshotWithCandidateLimit:(NSUInteger)limit {
    const char *rawInput = _api->get_input(_session);
    NSString *input = rawInput ? @(rawInput) : @"";
    NSString *preedit = @"";
    NSString *fullCandidate = nil;
    if (rawInput && *rawInput) {
        RIME_STRUCT(RimeContext, ctx);
        if (_api->get_context(_session, &ctx)) {
            preedit = [self preeditFromContext:&ctx];
            fullCandidate = [self fullInputCandidateFromContext:&ctx rawInput:rawInput session:_session];
            _api->free_context(&ctx);
        }
    }
    NSArray<NSString *> *candidates = (rawInput && *rawInput && limit > 0)
        ? [self candidatesFromIndex:0 limit:limit]
        : @[];
    return [[RimeSnapshot alloc] initWithInput:input
                                       preedit:preedit
                                    candidates:candidates
                            fullInputCandidate:fullCandidate
                                        commit:[self takeCommit]];
}
- (NSArray *)candidatesFromIndex:(NSUInteger)start limit:(NSUInteger)limit {
    return [self candidatesForSession:_session start:start limit:limit];
}
- (NSArray *)candidatesForSession:(RimeSessionId)session start:(NSUInteger)start limit:(NSUInteger)limit {
    NSMutableArray *result = [NSMutableArray array];
    RimeCandidateListIterator iterator = {0};
    if (start < INT_MAX && _api->candidate_list_from_index(session, &iterator, (int)start)) {
        while (result.count < limit && _api->candidate_list_next(&iterator))
            [result addObject:[self outputText:@(iterator.candidate.text)]];
        _api->candidate_list_end(&iterator);
    }
    return result;
}
- (NSArray *)previewCandidatesForInput:(NSString *)input {
    return [self previewCandidatesForInput:input limit:4];
}
- (NSArray *)previewCandidatesForInput:(NSString *)input limit:(NSUInteger)limit {
    return [self previewCandidatesForInput:input start:0 limit:limit];
}
- (BOOL)preparePreviewForInput:(NSString *)input {
    if (!_session || !input.length) return NO;
    if (!_previewSession) {
        _previewSession = _api->create_session();
        if (!_previewSession || !_api->select_schema(_previewSession, _schema.UTF8String)) {
            [self closePreview];
            return NO;
        }

        [self applyTraditional:_traditional session:_previewSession];
    }
    _api->clear_composition(_previewSession);
    BOOL usedSetInput = NO;
    if (RIME_API_AVAILABLE(_api, set_input)) {
        const char *raw = input.UTF8String;
        BOOL simple = raw && *raw;
        for (const char *ch = raw; simple && *ch; ++ch) {
            unsigned char c = (unsigned char)*ch;
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '\'' || c == ';')) simple = NO;
        }
        if (simple) {
            usedSetInput = _api->set_input(_previewSession, raw);
        }
    }
    if (!usedSetInput) {
        _api->clear_composition(_previewSession);
        for (const char *ch = input.UTF8String; *ch; ++ch) {
            BOOL hadComposition = strlen(_api->get_input(_previewSession) ?: "") > 0;
            _api->process_key(_previewSession, *ch, 0);
            [self captureCommitForSession:_previewSession learning:!hadComposition];
        }
    }
    return YES;
}
- (NSArray *)previewCandidatesForInput:(NSString *)input start:(NSUInteger)start limit:(NSUInteger)limit {
    if (![self preparePreviewForInput:input]) return @[];
    return [self candidatesForSession:_previewSession start:start limit:limit];
}
- (nullable NSString *)previewFullInputCandidateForInput:(NSString *)input {
    if (![self preparePreviewForInput:input]) return nil;
    const char *raw = _api->get_input(_previewSession);
    if (!raw || strcmp(raw, input.UTF8String) != 0) return nil;
    RIME_STRUCT(RimeContext, ctx);
    if (!_api->get_context(_previewSession, &ctx)) return nil;
    NSString *title = [self fullInputCandidateFromContext:&ctx rawInput:raw session:_previewSession];
    _api->free_context(&ctx);
    return title;
}
- (NSString *)previewReadingForInput:(NSString *)input title:(NSString *)title index:(NSInteger)index {
    if (!RIME_API_AVAILABLE(_api, highlight_candidate) || ![self preparePreviewForInput:input]) return nil;
    if (index < 0) {
        NSUInteger found = [[self candidatesForSession:_previewSession start:0 limit:32] indexOfObject:title];
        if (found == NSNotFound) return nil;
        index = (NSInteger)found;
    }
    _api->highlight_candidate(_previewSession, (NSUInteger)index);
    RIME_STRUCT(RimeContext, ctx);
    if (!_api->get_context(_previewSession, &ctx)) return nil;
    NSString *reading = nil;
    int slot = ctx.menu.highlighted_candidate_index;
    if (slot >= 0 && slot < ctx.menu.num_candidates && ctx.menu.page_no * ctx.menu.page_size + slot == index &&
        ctx.menu.candidates[slot].text && [[self outputText:@(ctx.menu.candidates[slot].text)] isEqualToString:title]) {
        reading = [self preeditFromContext:&ctx];
    }
    _api->free_context(&ctx);
    return reading;
}
- (NSDictionary<NSNumber *, NSString *> *)previewCompleteCandidatesForInput:(NSString *)input
                                                                   indexes:(NSArray<NSNumber *> *)indexes {
    if (indexes.count == 0 || !RIME_API_AVAILABLE(_api, highlight_candidate) || ![self preparePreviewForInput:input]) return @{};
    const char *raw = _api->get_input(_previewSession);
    if (!raw || strcmp(raw, input.UTF8String) != 0 || _api->get_caret_pos(_previewSession) != strlen(raw)) return @{};
    NSMutableDictionary *words = [NSMutableDictionary dictionaryWithCapacity:indexes.count];
    for (NSNumber *index in indexes) {
        if (index.integerValue < 0) continue;
        // An already-highlighted candidate reports no change. Verify its actual slot below.
        _api->highlight_candidate(_previewSession, index.unsignedIntegerValue);
        RIME_STRUCT(RimeContext, ctx);
        if (!_api->get_context(_previewSession, &ctx)) continue;
        int slot = ctx.menu.highlighted_candidate_index;
        if (slot >= 0 && slot < ctx.menu.num_candidates && ctx.menu.page_no >= 0 && ctx.menu.page_size > 0 &&
            (NSUInteger)ctx.menu.page_no * (NSUInteger)ctx.menu.page_size + (NSUInteger)slot == index.unsignedIntegerValue &&
            ctx.composition.sel_start == 0 && ctx.composition.sel_end == ctx.composition.length &&
            ctx.composition.cursor_pos == ctx.composition.length && ctx.commit_text_preview) {
            const char *title = ctx.menu.candidates[slot].text;
            if (title && strcmp(title, ctx.commit_text_preview) == 0) words[index] = [self outputText:@(title)];
        }
        _api->free_context(&ctx);
    }
    return words;
}
// librime's standard translators do not honor a _no_learning option.
// Backspace on an empty context reverts the just-created learning transaction;
// consume it here, before another key can make that transaction permanent.
- (NSString *)captureCommitForSession:(RimeSessionId)session learning:(BOOL)learning {
    RIME_STRUCT(RimeCommit, value);
    if (!_api->get_commit(session, &value)) return @"";
    NSString *text = @(value.text);
    _api->free_commit(&value);
    if (!learning && text.length && !strlen(_api->get_input(session) ?: "")) {
        _api->process_key(session, 0xff08, 0);
    }
    return [self outputText:text];
}
- (BOOL)key:(int)code {
    BOOL hadComposition = self.input.length > 0;
    BOOL handled = _api->process_key(_session, code, 0);
    NSString *text = [self captureCommitForSession:_session learning:(_learningEnabled && !_provisionalSelection) || !hadComposition];
    if (text.length) _provisionalSelection = NO;
    _pendingCommit = [(_pendingCommit ?: @"") stringByAppendingString:text];
    return handled;
}
- (void)setLearningEnabled:(BOOL)enabled { _learningEnabled = enabled; }
// After highlighting a partial candidate, librime appends the unconsumed raw
// keys after composition.sel_end. Unlike the highlighted preedit, this tail
// has not passed through the schema's spelling formatter.
- (NSString *)remainingInputAfterHighlight:(NSUInteger)index {
    if (!RIME_API_AVAILABLE(_api, highlight_candidate) || !RIME_API_AVAILABLE(_api, set_input)) return nil;
    // Highlighting the already-active candidate returns false (no change),
    // including candidate zero before an unrecognized suffix. Read the context
    // regardless, and verify which candidate is actually highlighted.
    _api->highlight_candidate(_session, index);
    RIME_STRUCT(RimeContext, ctx);
    if (!_api->get_context(_session, &ctx)) return nil;
    NSString *remaining = nil;
    NSUInteger highlighted = ctx.menu.page_no * ctx.menu.page_size + ctx.menu.highlighted_candidate_index;
    if (highlighted == index && ctx.composition.preedit && ctx.composition.sel_end > 0 &&
        ctx.composition.sel_end < ctx.composition.cursor_pos &&
        ctx.composition.cursor_pos <= ctx.composition.length &&
        _api->get_caret_pos(_session) == strlen(_api->get_input(_session) ?: "")) {
        const char *tail = ctx.composition.preedit + ctx.composition.sel_end;
        NSString *suffix = [[NSString alloc] initWithBytes:tail
            length:ctx.composition.cursor_pos - ctx.composition.sel_end encoding:NSUTF8StringEncoding];
        NSString *raw = self.input;
        if (suffix.length && suffix.length < raw.length && [raw hasSuffix:suffix]) remaining = suffix;
    }
    _api->free_context(&ctx);
    return remaining;
}
- (BOOL)select:(NSUInteger)index {
    NSString *title = [self candidatesFromIndex:index limit:1].firstObject;
    if (!title) return NO;
    NSString *remaining = [self remainingInputAfterHighlight:index];
    if (remaining) {
        // Publish only the confirmed prefix. All input paths now operate on
        // the remaining keys, including corrections, raw Return and deletion.
        _api->clear_composition(_session);
        _api->set_input(_session, remaining.UTF8String);
        _provisionalSelection = NO;
        _pendingCommit = [(_pendingCommit ?: @"") stringByAppendingString:title];
        return YES;
    }
    BOOL allowLearning = _learningEnabled && !_provisionalSelection;
    BOOL selected = _api->select_candidate(_session, index);
    if (selected && !_learningEnabled) _provisionalSelection = YES;
    NSString *text = [self captureCommitForSession:_session learning:allowLearning];
    if (text.length || !self.input.length) _provisionalSelection = NO;
    _pendingCommit = [(_pendingCommit ?: @"") stringByAppendingString:text];
    return selected;
}
- (void)clear { _api->clear_composition(_session); _pendingCommit = @""; _provisionalSelection = NO; }
- (BOOL)replaceInput:(NSString *)input {
    if (!RIME_API_AVAILABLE(_api, set_input)) return NO;
    [self clear];
    return _api->set_input(_session, input.UTF8String);
}
- (NSString *)takeCommit {
    NSString *text = _pendingCommit ?: @"";
    _pendingCommit = @"";
    return text;
}
- (BOOL)deploy { return _api->deploy(); }
- (BOOL)sync {
    [self closePreview];
    if (_session) { _api->destroy_session(_session); _session = 0; }
    if (!_api->run_task("installation_update")) return NO;
    // SynchronizeAll enumerates existing databases. Restore the first snapshot
    // for each missing database so a newly paired phone learns on its first sync.
    char directory[PATH_MAX] = {0};
    _api->get_sync_dir_s(directory, sizeof(directory));
    NSString *root = @(directory);
    NSFileManager *fs = NSFileManager.defaultManager;
    RimeModule *module = _api->find_module("levers");
    if (!module || !module->get_api) return NO;
    RimeLeversApi *levers = (RimeLeversApi *)module->get_api();
    for (NSString *relative in [fs subpathsAtPath:root]) {
        if (![relative hasSuffix:@".userdb.txt"] || relative.pathComponents.count != 2) continue;
        NSString *name = relative.lastPathComponent.stringByDeletingPathExtension;
        NSString *existing = [_user stringByAppendingPathComponent:name];
        if ([fs fileExistsAtPath:existing]) continue;
        NSString *file = [root stringByAppendingPathComponent:relative];
        if (!levers->restore_user_dict(file.fileSystemRepresentation)) return NO;
    }
    return _api->run_task("user_dict_sync");
}
- (void)close {
    if (_api) {
        [self closePreview];
        if (_session) _api->destroy_session(_session);
        _session = 0;
        _api->finalize();
        _api = NULL;
    }
    if (_ownsRuntime) {
        @synchronized (RimeEngine.class) { processInUse = NO; _ownsRuntime = NO; }
    }
    if (_lock >= 0) { close(_lock); _lock = -1; }
}
- (void)dealloc { [self close]; }
@end
