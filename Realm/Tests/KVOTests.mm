////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMTestCase.h"

#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.hpp"
#import "RLMPredicateUtil.h"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"

#import <memory>
#import <vector>

RLM_ARRAY_TYPE(KVOObject)

@interface KVOObject : RLMObject
@property BOOL                 boolCol;
@property int16_t              int16Col;
@property int32_t              int32Col;
@property int64_t              int64Col;
@property float                floatCol;
@property double               doubleCol;
@property bool                 cBoolCol;
@property NSString            *stringCol;
@property NSData              *binaryCol;
@property NSDate              *dateCol;
@property KVOObject           *objectCol;
@property RLMArray<KVOObject> *arrayCol;
@end
@implementation KVOObject
@end

@interface PlainKVOObject : NSObject
@property BOOL            boolCol;
@property int16_t         int16Col;
@property int32_t         int32Col;
@property int64_t         int64Col;
@property float           floatCol;
@property double          doubleCol;
@property bool            cBoolCol;
@property NSString       *stringCol;
@property NSData         *binaryCol;
@property NSDate         *dateCol;
@property KVOObject      *objectCol;
@property NSMutableArray *arrayCol;
@end
@implementation PlainKVOObject
@end

@interface KVOTests : RLMTestCase
- (id)objectToObserveForObject:(id)obj;
@end

struct KVONotification {
    NSString *keyPath;
    id object;
    NSDictionary *change;
};

class KVORecorder {
    id _observer;
    id _obj;
    NSString *_keyPath;
    RLMRealm *_mutationRealm;
    RLMRealm *_observationRealm;

public:
    std::vector<KVONotification> notifications;

    KVORecorder(id observer, id obj, NSString *keyPath, int options = NSKeyValueObservingOptionOld|NSKeyValueObservingOptionNew)
    : _observer(observer)
    , _obj([observer objectToObserveForObject:obj])
    , _keyPath(keyPath)
    , _mutationRealm([obj respondsToSelector:@selector(realm)] ? (RLMRealm *)[obj realm] : nil)
    , _observationRealm([_obj respondsToSelector:@selector(realm)] ? (RLMRealm *)[_obj realm] : nil)
    {
        [_obj addObserver:observer forKeyPath:keyPath options:options context:this];
    }

    ~KVORecorder() {
        [_obj removeObserver:_observer forKeyPath:_keyPath context:this];
    }

    void operator()(NSString *key, id obj, NSDictionary *changeDictionary) {
        notifications.push_back(KVONotification{key, obj, changeDictionary});
    }

    void refresh() {
        if (_mutationRealm != _observationRealm) {
            [_mutationRealm commitWriteTransaction];
            [_observationRealm refresh];
            [_mutationRealm beginWriteTransaction];
        }
    }
};

@implementation KVOTests
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (*static_cast<KVORecorder *>(context))(keyPath, object, change);
}

- (id)objectToObserveForObject:(id)obj {
    return obj;
}
@end

@interface KVOSingleObjectTests : KVOTests
@property (nonatomic, strong) RLMRealm *realm;
@end

// Validate that `recorder` has enough notifications for `index` to be valid,
// and if it does validate that the notification is correct
#define AssertChanged(recorder, index, from, to) do { \
    (recorder).refresh(); \
    XCTAssertGreaterThan((recorder).notifications.size(), index); \
    if ((recorder).notifications.size() > index) { \
        XCTAssertEqualObjects((from), (recorder).notifications[index].change[NSKeyValueChangeOldKey]); \
        XCTAssertEqualObjects((to), (recorder).notifications[index].change[NSKeyValueChangeNewKey]); \
    } \
} while (false)

// still to test:
//   - standalone
//   - standalone added to realm after observer added
//   - ignored properties
//   - Prior called at right time

@implementation KVOSingleObjectTests
- (void)setUp {
    [super setUp];
    _realm = RLMRealm.defaultRealm;
    [_realm beginWriteTransaction];
}

- (void)tearDown {
    [self.realm cancelWriteTransaction];
    self.realm = nil;
    [super tearDown];
}

- (id)createObject {
    return [KVOObject createInDefaultRealmWithObject:@[@NO, @1, @2, @3, @0, @0, @NO, @"",
                                                       NSData.data, [NSDate dateWithTimeIntervalSinceReferenceDate:0],
                                                       NSNull.null, NSNull.null]];
}

- (void)testSimple {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = 10;
        AssertChanged(r, 0U, @2, @10);
    }
    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = 1;
        AssertChanged(r, 0U, @10, @1);
    }
}

- (void)testSelfAssignmentNotifies {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = obj.int32Col;
        AssertChanged(r, 0U, @2, @2);
    }
}

- (void)testMultipleObserversAreNotified {
    KVOObject *obj = [self createObject];
    {
        KVORecorder r1(self, obj, @"int32Col");
        KVORecorder r2(self, obj, @"int32Col");
        KVORecorder r3(self, obj, @"int32Col");
        obj.int32Col = 10;
        AssertChanged(r1, 0U, @2, @10);
        AssertChanged(r2, 0U, @2, @10);
        AssertChanged(r3, 0U, @2, @10);
    }
}

- (void)testOnlyObserversForTheCorrectPropertyAreNotified {
    assert(_realm);
    KVOObject *obj = [self createObject];
    {
        KVORecorder r16(self, obj, @"int16Col");
        KVORecorder r32(self, obj, @"int32Col");
        KVORecorder r64(self, obj, @"int64Col");

        obj.int16Col = 2;
        AssertChanged(r16, 0U, @1, @2);
        XCTAssertEqual(1U, r16.notifications.size());
        XCTAssertEqual(0U, r32.notifications.size());
        XCTAssertEqual(0U, r64.notifications.size());

        obj.int32Col = 2;
        AssertChanged(r32, 0U, @2, @2);
        XCTAssertEqual(1U, r16.notifications.size());
        XCTAssertEqual(1U, r32.notifications.size());
        XCTAssertEqual(0U, r64.notifications.size());

        obj.int64Col = 2;
        AssertChanged(r64, 0U, @3, @2);
        XCTAssertEqual(1U, r16.notifications.size());
        XCTAssertEqual(1U, r32.notifications.size());
        XCTAssertEqual(1U, r64.notifications.size());
    }
}

- (bool)collapsesNotifications {
    return false;
}

- (void)testMultipleChangesWithSingleObserver {
    KVOObject *obj = [self createObject];
    KVORecorder r(self, obj, @"int32Col");

    obj.int32Col = 1;
    obj.int32Col = 2;
    obj.int32Col = 3;
    obj.int32Col = 3;

    if (self.collapsesNotifications) {
        AssertChanged(r, 0U, @2, @3);
    }
    else {
        AssertChanged(r, 0U, @2, @1);
        AssertChanged(r, 1U, @1, @2);
        AssertChanged(r, 2U, @2, @3);
        AssertChanged(r, 3U, @3, @3);
    }
}

- (void)testOnlyObserversForTheCorrectObjectAreNotified {
    KVOObject *obj1 = [self createObject];
    KVOObject *obj2 = [self createObject];

    KVORecorder r1(self, obj1, @"int32Col");
    KVORecorder r2(self, obj2, @"int32Col");

    obj1.int32Col = 10;
    AssertChanged(r1, 0U, @2, @10);
    XCTAssertEqual(0U, r2.notifications.size());

    obj2.int32Col = 5;
    XCTAssertEqual(1U, r1.notifications.size());
    AssertChanged(r2, 0U, @2, @5);
}

- (void)testOptionsInitial {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"int32Col", 0);
        XCTAssertEqual(0U, r.notifications.size());
    }
    {
        KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionInitial);
        XCTAssertEqual(1U, r.notifications.size());
    }
}

- (void)testOptionsOld {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"int32Col", 0);
        obj.int32Col = 0;
        r.refresh();
        XCTAssertNil(r.notifications[0].change[NSKeyValueChangeOldKey]);
    }
    {
        KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionOld);
        obj.int32Col = 0;
        r.refresh();
        XCTAssertNotNil(r.notifications[0].change[NSKeyValueChangeOldKey]);
    }
}

- (void)testOptionsNew {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"int32Col", 0);
        obj.int32Col = 0;
        r.refresh();
        XCTAssertNil(r.notifications[0].change[NSKeyValueChangeNewKey]);
    }
    {
        KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionNew);
        obj.int32Col = 0;
        r.refresh();
        XCTAssertNotNil(r.notifications[0].change[NSKeyValueChangeNewKey]);
    }
}

- (void)testOptionsPrior {
    KVOObject *obj = [self createObject];

    KVORecorder r(self, obj, @"int32Col", NSKeyValueObservingOptionNew|NSKeyValueObservingOptionPrior);
    obj.int32Col = 0;
    r.refresh();

    XCTAssertEqual(2U, r.notifications.size());
    XCTAssertNil(r.notifications[0].change[NSKeyValueChangeNewKey]);
    XCTAssertEqualObjects(@YES, r.notifications[0].change[NSKeyValueChangeNotificationIsPriorKey]);
    XCTAssertNotNil(r.notifications[1].change[NSKeyValueChangeNewKey]);
    XCTAssertNil(r.notifications[1].change[NSKeyValueChangeNotificationIsPriorKey]);
}

- (void)testAllPropertyTypes {
    KVOObject *obj = [self createObject];

    {
        KVORecorder r(self, obj, @"boolCol");
        obj.boolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
    }

    {
        KVORecorder r(self, obj, @"int16Col");
        obj.int16Col = 0;
        AssertChanged(r, 0U, @1, @0);
    }

    {
        KVORecorder r(self, obj, @"int32Col");
        obj.int32Col = 0;
        AssertChanged(r, 0U, @2, @0);
    }

    {
        KVORecorder r(self, obj, @"int64Col");
        obj.int64Col = 0;
        AssertChanged(r, 0U, @3, @0);
    }

    {
        KVORecorder r(self, obj, @"floatCol");
        obj.floatCol = 1.0f;
        AssertChanged(r, 0U, @0, @1);
    }

    {
        KVORecorder r(self, obj, @"doubleCol");
        obj.doubleCol = 1.0;
        AssertChanged(r, 0U, @0, @1);
    }

    {
        KVORecorder r(self, obj, @"cBoolCol");
        obj.cBoolCol = YES;
        AssertChanged(r, 0U, @NO, @YES);
    }

    {
        KVORecorder r(self, obj, @"stringCol");
        obj.stringCol = @"abc";
        AssertChanged(r, 0U, @"", @"abc");
    }

    {
        KVORecorder r(self, obj, @"binaryCol");
        NSData *data = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
        obj.binaryCol = data;
        AssertChanged(r, 0U, NSData.data, data);
    }

    {
        KVORecorder r(self, obj, @"dateCol");
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:1];
        obj.dateCol = date;
        AssertChanged(r, 0U, [NSDate dateWithTimeIntervalSinceReferenceDate:0], date);
    }

    {
        KVORecorder r(self, obj, @"objectCol");
        obj.objectCol = obj;
        AssertChanged(r, 0U, NSNull.null, obj);
    }

    {
        KVORecorder r(self, obj, @"arrayCol");
        [obj.arrayCol addObject:obj];
        r.refresh();
        XCTAssertEqual(0U, r.notifications.size());
    }
}
@end

// Run the tests on a non-RLMObject to sanity-check that we're testing the
// correct behavior
@interface KVONSObjectTests : KVOSingleObjectTests
@end
@implementation KVONSObjectTests
- (id)createObject {
    PlainKVOObject *obj = [PlainKVOObject new];
    obj.int16Col = 1;
    obj.int32Col = 2;
    obj.int64Col = 3;
    obj.binaryCol = NSData.data;
    obj.dateCol = [NSDate dateWithTimeIntervalSinceReferenceDate:0];
    obj.arrayCol = [NSMutableArray array];
    return obj;
}
@end

// Run the tests observing a different accessor for the same backing row
@interface KvoMultipleAccessorsTests : KVOSingleObjectTests
@end
@implementation KvoMultipleAccessorsTests
- (id)objectToObserveForObject:(RLMObject *)obj {
    RLMObject *copy = [[obj.objectSchema.accessorClass alloc] initWithRealm:obj.realm schema:obj.objectSchema];
    copy->_row = obj->_row;
    return copy;
}
@end

// Run the tests observing an accessor from a different RLMRealm instance
// which is updated via the transaction logs
@interface KvoMultipleRealmsTests : KVOSingleObjectTests
@property RLMRealm *secondaryRealm;
@end

@implementation KvoMultipleRealmsTests
- (void)setUp {
    [super setUp];
    self.secondaryRealm = [[RLMRealm alloc] initWithPath:self.realm.path key:nil readOnly:NO inMemory:NO dynamic:NO error:nil];
    RLMRealmSetSchema(self.secondaryRealm, [self.realm.schema shallowCopy], false);
}

- (void)tearDown {
    self.secondaryRealm = nil;
    [super tearDown];
}

- (id)objectToObserveForObject:(RLMObject *)obj {
    [self.realm commitWriteTransaction];
    [self.realm beginWriteTransaction];

    RLMObject *copy = [[obj.objectSchema.accessorClass alloc] initWithRealm:self.secondaryRealm
                                                                     schema:self.secondaryRealm.schema[obj.objectSchema.className]];
    copy->_row = (*copy.objectSchema.table)[obj->_row.get_index()];
    return copy;
}

- (bool)collapsesNotifications {
    return true;
}
@end
