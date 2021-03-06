//
//  ADTokenCacheStoreKeyTests.m
//  ADALiOS
//
//  Created by Boris Vidolov on 12/17/13.
//  Copyright (c) 2013 MS Open Tech. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "ADTokenCacheStoreKey.h"
#import "XCTestCase+TestHelperMethods.h"

@interface ADTokenCacheStoreKeyTests : XCTestCase
{
    NSString* mAuthority;
    NSString* mResource;
    NSString* mClientId;
}

@end

@implementation ADTokenCacheStoreKeyTests

- (void)setUp
{
    [super setUp];
    // Put setup code here; it will be run once, before the first test case.
    mAuthority = @"https://login.windows.net";;
    mResource = @"http://mywebApi.com";
    mClientId = @"myclientid";
}

- (void)tearDown
{
    // Put teardown code here; it will be run once, after the last test case.
    [super tearDown];
}

- (void)testCreate
{
    ADAuthenticationError* error;
    ADTokenCacheStoreKey* key = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:mClientId error:&error];
    ADAssertNoError;
    XCTAssertNotNil(key);
    
    //Bad authority:
    error = nil;
    ADTokenCacheStoreKey* badKey = [ADTokenCacheStoreKey keyWithAuthority:nil resource:mResource clientId:mClientId error:&error];
    [self validateFactoryForInvalidArgument:@"authority"
                             returnedObject:badKey
                                      error:error];
    error = nil;
    badKey = [ADTokenCacheStoreKey keyWithAuthority:@"   " resource:mResource clientId:mClientId error:&error];
    [self validateFactoryForInvalidArgument:@"authority"
                             returnedObject:badKey
                                      error:error];

    //Bad clientId
    error = nil;
    badKey = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:nil error:&error];
    [self validateFactoryForInvalidArgument:@"clientId"
                             returnedObject:badKey
                                      error:error];
    error = nil;
    badKey = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:@"    " error:&error];
    [self validateFactoryForInvalidArgument:@"clientId"
                             returnedObject:badKey
                                      error:error];
    
    error = nil;
    ADTokenCacheStoreKey* normal = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:mClientId error:&error];
    ADAssertNoError;
    XCTAssertNotNil(normal);
    
    error = nil;
    ADTokenCacheStoreKey* broad = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:nil clientId:mClientId error:&error];
    ADAssertNoError;
    XCTAssertNotNil(broad);
}

-(void) assertKey: (ADTokenCacheStoreKey*) key1
         equalsTo: (ADTokenCacheStoreKey*) key2
{
    XCTAssertTrue([key1 isEqual:key2]);
    XCTAssertTrue([key2 isEqual:key1]);
    XCTAssertEqual(key1.hash, key2.hash);
}

-(void) assertKey: (ADTokenCacheStoreKey*) key1
      notEqualsTo: (ADTokenCacheStoreKey*) key2
{
    XCTAssertFalse([key1 isEqual:key2]);
    XCTAssertFalse([key2 isEqual:key1]);
    XCTAssertNotEqual(key1.hash, key2.hash);
}

- (void)testCompare
{
    ADAuthenticationError* error;
    ADTokenCacheStoreKey* normal = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:mClientId error:&error];
    ADAssertNoError;
    XCTAssertNotNil(normal);
    [self assertKey:normal equalsTo:normal];//Self
    [self assertKey:normal notEqualsTo:nil];
    
    {
        error = nil;
        ADTokenCacheStoreKey* same = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:mClientId error:&error];
        ADAssertNoError;
        XCTAssertNotNil(same);
        [self assertKey:normal equalsTo:normal];
    }
    
    {
        error = nil;
        ADTokenCacheStoreKey* differentAuth = [ADTokenCacheStoreKey keyWithAuthority:@"https://login.windows.com" resource:mResource clientId:mClientId error:&error];
        ADAssertNoError;
        XCTAssertNotNil(differentAuth);
        [self assertKey:normal notEqualsTo:differentAuth];
    }
    
    {
        error = nil;
        ADTokenCacheStoreKey* differentRes = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:@"another resource" clientId:mClientId error:&error];
        ADAssertNoError;
        XCTAssertNotNil(differentRes);
        [self assertKey:normal notEqualsTo:differentRes];
    }
    
    {
        error = nil;
        ADTokenCacheStoreKey* differentClient = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:mResource clientId:@"another clientid" error:&error];
        ADAssertNoError;
        XCTAssertNotNil(differentClient);
        [self assertKey:normal notEqualsTo:differentClient];
    }
    
    error = nil;
    ADTokenCacheStoreKey* broad = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:nil clientId:mClientId error:&error];
    ADAssertNoError;
    XCTAssertNotNil(broad);
    [self assertKey:broad equalsTo:broad];
    [self assertKey:broad notEqualsTo:normal];
    
    {
        error = nil;
        ADTokenCacheStoreKey* sameBroad = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:nil clientId:mClientId error:&error];
        ADAssertNoError;
        XCTAssertNotNil(sameBroad);
        [self assertKey:broad equalsTo:sameBroad];
    }

    {
        error = nil;
        ADTokenCacheStoreKey* differentAuthBroad = [ADTokenCacheStoreKey keyWithAuthority:@"https://login.windows.com" resource:nil clientId:mClientId error:&error];
        ADAssertNoError;
        XCTAssertNotNil(differentAuthBroad);
        [self assertKey:broad notEqualsTo:differentAuthBroad];
    }
    
    {
        error = nil;
        ADTokenCacheStoreKey* differentClientBroad = [ADTokenCacheStoreKey keyWithAuthority:mAuthority resource:nil clientId:@"another authority" error:&error];
        ADAssertNoError;
        XCTAssertNotNil(differentClientBroad);
        [self assertKey:broad notEqualsTo:differentClientBroad];
    }
}


@end
