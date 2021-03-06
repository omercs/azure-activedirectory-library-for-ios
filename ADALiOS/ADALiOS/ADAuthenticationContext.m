// Created by Boris Vidolov on 10/10/13.
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

#import "ADALiOS.h"
#import "ADAuthenticationContext.h"
#import "ADDefaultTokenCacheStore.h"
#import "ADAuthenticationResult+Internal.h"
#import "ADOAuth2Constants.h"
#import "WebAuthenticationBroker.h"
#import "ADAuthenticationSettings.h"
#import <libkern/OSAtomic.h>
#import "NSURLExtensions.h"
#import "NSDictionaryExtensions.h"
#import "HTTPWebRequest.h"
#import "HTTPWebResponse.h"

NSString* const multiUserError = @"The token cache store for this resource contain more than one user. Please set the 'userId' parameter to determine which one to be used.";
NSString* const unknownError = @"Uknown error.";
NSString* const credentialsNeeded = @"The user credentials are need to obtain access token. Please call acquireToken with 'promptBehavior' not set to AD_PROMPT_NEVER";
NSString* const serverError = @"The authentication server returned an error: %@.";

//Used for the callback of obtaining the OAuth2 code:
typedef void(^ADAuthorizationCodeCallback)(NSString*, ADAuthenticationError*);

static volatile int sDialogInProgress = 0;

@implementation ADAuthenticationContext

-(id) init
{
    //Ensure that the appropriate init function is called. This will cause the runtime to throw.
    [super doesNotRecognizeSelector:_cmd];
    return nil;
}

//A wrapper around checkAndHandleBadArgument. Assumes that "completionMethod" is in scope:
#define HANDLE_ARGUMENT(ARG) \
if (![self checkAndHandleBadArgument:ARG \
                        argumentName:TO_NSSTRING(#ARG) \
                     completionBlock:completionBlock]) \
{ \
     return; \
}

/*! Verifies that the string parameter is not nil or empty. If it is,
 the method generates an error and set it to an authentication result.
 Then the method calls the callback with the result.
 The method returns if the argument is valid. If the method returns false,
 the calling method should return. */
-(BOOL) checkAndHandleBadArgument: (NSString*) argumentValue
                     argumentName: (NSString*) argumentName
                  completionBlock: (ADAuthenticationCallback)completionBlock
{
    if ([NSString isStringNilOrBlank:argumentValue])
    {
        ADAuthenticationError* argumentError = [ADAuthenticationError errorFromArgument:argumentValue argumentName:argumentName];
        ADAuthenticationResult* result = [ADAuthenticationResult resultFromError:argumentError];
        completionBlock(result);//Call the callback to tell about the result
        return NO;
    }
    else
    {
        return YES;
    }
}

+(NSString*) canonicalizeAuthority: (NSString*) authority
{
    if ([NSString isStringNilOrBlank:authority])
    {
        return nil;
    }
    
    NSString* trimmedAuthority = [[authority trimmedString] lowercaseString];
    //Start with the trailing slash to ensure that the function covers "<authority>/authorize/" case.
    if ( [trimmedAuthority hasSuffix:@"/" ] )//Remove trailing slash
    {
        trimmedAuthority = [trimmedAuthority substringToIndex:trimmedAuthority.length - 1];
    }
    
    NSURL* url = [NSURL URLWithString:trimmedAuthority];
    if (!url)
    {
        NSString* message = [NSString stringWithFormat:@"Authority %@", authority];
        AD_LOG_WARN(@"The authority is not a valid URL", message);
        return nil;
    }
    NSString* scheme = url.scheme;
    if (![scheme isEqualToString:@"https"])
    {
        NSString* message = [NSString stringWithFormat:@"Authority %@", authority];
        AD_LOG_WARN(@"Non HTTPS protocol for the authority", message);
        return nil;
    }
    
    // Final step is trimming any trailing /authorize or /token from the URL
    // to get to the base URL for the authorization server. After that, we
    // append either /authorize or /token dependent on the request that
    // is being made to the server.
    if ( [trimmedAuthority hasSuffix:OAUTH2_AUTHORIZE_SUFFIX] )
    {
        trimmedAuthority = [trimmedAuthority substringToIndex:trimmedAuthority.length - OAUTH2_AUTHORIZE_SUFFIX.length];
    }
    else if ( [trimmedAuthority hasSuffix:OAUTH2_TOKEN_SUFFIX] )
    {
        trimmedAuthority = [trimmedAuthority substringToIndex:trimmedAuthority.length - OAUTH2_TOKEN_SUFFIX.length];
    }
    
    return trimmedAuthority;
}

-(id) initWithAuthority: (NSString*) authority
      validateAuthority: (BOOL)bValidate
        tokenCacheStore: (id<ADTokenCacheStoring>)tokenCache
                  error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    NSString* extractedAuthority = [self.class canonicalizeAuthority:authority];
    RETURN_ON_INVALID_ARGUMENT(!extractedAuthority, authority, nil);
    
    self = [super init];
    if (self)
    {
        _authority = extractedAuthority;
        _validateAuthority = bValidate;
        _tokenCacheStore = tokenCache;
    }
    return self;
}


+(ADAuthenticationContext*) contextWithAuthority: (NSString*) authority
                                           error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    return [self contextWithAuthority: authority
                    validateAuthority: YES
                      tokenCacheStore: [ADDefaultTokenCacheStore sharedInstance]
                                error: error];
}

+(ADAuthenticationContext*) contextWithAuthority: (NSString*) authority
                               validateAuthority: (BOOL) bValidate
                                           error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY
    return [self contextWithAuthority: authority
                    validateAuthority: bValidate
                      tokenCacheStore: [ADDefaultTokenCacheStore sharedInstance]
                                error: error];
}

+(ADAuthenticationContext*) contextWithAuthority: (NSString*) authority
                                 tokenCacheStore: (id<ADTokenCacheStoring>) tokenCache
                                           error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    return [self contextWithAuthority:authority
                    validateAuthority:YES
                      tokenCacheStore:tokenCache
                                error:error];
}

+(ADAuthenticationContext*) contextWithAuthority: (NSString*) authority
                               validateAuthority: (BOOL)bValidate
                                 tokenCacheStore: (id<ADTokenCacheStoring>)tokenCache
                                           error: (ADAuthenticationError* __autoreleasing *) error
{
    API_ENTRY;
    RETURN_NIL_ON_NIL_EMPTY_ARGUMENT(authority);
    
    ADAuthenticationContext* context = [self alloc];
    if (context)
    {
        return [context initWithAuthority: authority
                                validateAuthority: bValidate
                                  tokenCacheStore: tokenCache
                                            error: error];
    }
    return context;
}


-(void) acquireToken: (NSString*) resource
            clientId: (NSString*) clientId
         redirectUri: (NSURL*) redirectUri
     completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    return [self internalAcquireToken:resource
                             clientId:clientId
                          redirectUri:redirectUri
                       promptBehavior:AD_PROMPT_AUTO
                               userId:nil
                                scope:nil
                 extraQueryParameters:nil
                             tryCache:YES
                      completionBlock:completionBlock];
}

-(void) acquireToken: (NSString*) resource
            clientId: (NSString*) clientId
         redirectUri: (NSURL*) redirectUri
              userId: (NSString*) userId
     completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    [self internalAcquireToken:resource
                      clientId:clientId
                   redirectUri:redirectUri
                promptBehavior:AD_PROMPT_AUTO
                        userId:userId
                         scope:nil
          extraQueryParameters:nil
                      tryCache:YES
               completionBlock:completionBlock];
}


-(void) acquireToken: (NSString*) resource
            clientId: (NSString*)clientId
         redirectUri: (NSURL*) redirectUri
              userId: (NSString*) userId
extraQueryParameters: (NSString*) queryParams
     completionBlock: (ADAuthenticationCallback) completionBlock
{
    API_ENTRY;
    [self internalAcquireToken:resource
                      clientId:clientId
                   redirectUri:redirectUri
                promptBehavior:AD_PROMPT_AUTO
                        userId:userId
                         scope:nil
          extraQueryParameters:queryParams
                      tryCache:YES
               completionBlock:completionBlock];
}

//Returns YES if we shouldn't attempt other means to get access token.
//
-(BOOL) isFinalResult: (ADAuthenticationResult*) result
{
    return (AD_SUCCEEDED == result.status) /* access token provided, no need to try anything else */
    || (result.error && !result.error.protocolCode); //Connection is down, server is unreachable or DNS error. No need to try refresh tokens.
}

/*Attemps to use the cache. Returns YES if an attempt was successful or if an
 internal asynchronous call will proceed the processing. */
-(void) attemptToUseCacheItem: (ADTokenCacheStoreItem*) item
               useAccessToken: (BOOL) useAccessToken
                     resource: (NSString*) resource
                     clientId: (NSString*) clientId
                  redirectUri: (NSURL*) redirectUri
               promptBehavior: (ADPromptBehavior) promptBehavior
                       userId: (NSString*) userId
         extraQueryParameters: (NSString*) queryParams
              completionBlock: (ADAuthenticationCallback)completionBlock
{
    //All of these should be set before calling this method:
    THROW_ON_NIL_ARGUMENT(item);
    THROW_ON_NIL_EMPTY_ARGUMENT(resource);
    THROW_ON_NIL_EMPTY_ARGUMENT(clientId);
    THROW_ON_NIL_ARGUMENT(completionBlock);
    
    if (useAccessToken)
    {
        //Access token is good, just use it:
        ADAuthenticationResult* result = [ADAuthenticationResult resultFromTokenCacheStoreItem:item multiResourceRefreshToken:NO];
        completionBlock(result);
        return;
    }
    
    if ([NSString isStringNilOrBlank:item.refreshToken])
    {
        completionBlock([ADAuthenticationResult resultFromError:
                         [ADAuthenticationError unexpectedInternalError:@"Attempting to use an item without refresh token."]]);
        return;
    }
    
    //Now attempt to use the refresh token of the passed cache item:
    [self internalAcquireTokenByRefreshToken:item.refreshToken
                                    clientId:clientId
                                    resource:resource
                                      userId:item.userInformation.userId
                                   cacheItem:item
                             completionBlock:^(ADAuthenticationResult *result)
     {
         //Asynchronous block:
         if ([self isFinalResult:result])
         {
             completionBlock(result);
             return;
         }
         
         //Try other means of getting access token result:
         if (!item.multiResourceRefreshToken)//Try multi-resource refresh token if not currently trying it
         {
             ADTokenCacheStoreKey* broadKey = [ADTokenCacheStoreKey keyWithAuthority:self.authority resource:nil clientId:clientId error:nil];
             if (broadKey)
             {
                 BOOL useAccessToken;
                 ADAuthenticationError* error;
                 ADTokenCacheStoreItem* broadItem = [self findCacheItemWithKey:broadKey userId:userId useAccessToken:&useAccessToken error:&error];
                 if (error)
                 {
                     completionBlock([ADAuthenticationResult resultFromError:error]);
                     return;
                 }
                 
                 if (broadItem)
                 {
                     if (!broadItem.multiResourceRefreshToken)
                     {
                         AD_LOG_WARN(@"Unexpected", @"Multi-resource refresh token expected here.");
                         //Recover (avoid infinite recursion):
                         completionBlock(result);
                         return;
                     }
                     
                     //Call recursively with the cache item containing a multi-resource refresh token:
                     [self attemptToUseCacheItem:broadItem
                                  useAccessToken:NO
                                        resource:resource
                                        clientId:clientId
                                     redirectUri:redirectUri
                                  promptBehavior:promptBehavior
                                          userId:userId
                            extraQueryParameters:queryParams
                                 completionBlock:completionBlock];
                     return;//The call above takes over, no more processing
                 }//broad item
             }//key
         }//!item.multiResourceRefreshToken
         
         //The refresh token attempt failed and no other suitable refresh token found
         //call acquireToken
         [self internalAcquireToken: resource
                           clientId: clientId
                        redirectUri: redirectUri
                     promptBehavior: promptBehavior
                             userId: userId
                              scope: nil
               extraQueryParameters: queryParams
                           tryCache:NO
                    completionBlock: completionBlock];
    }];//End of the refreshing token completion block, executed asynchronously.
}

-(void) acquireToken: (NSString*) resource
            clientId: (NSString*) clientId
         redirectUri: (NSURL*) redirectUri
      promptBehavior: (ADPromptBehavior) promptBehavior
              userId: (NSString*) userId
extraQueryParameters: (NSString*) queryParams
     completionBlock: (ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    THROW_ON_NIL_ARGUMENT(completionBlock);//The only argument that throws
    [self internalAcquireToken:resource
                      clientId:clientId
                   redirectUri:redirectUri
                promptBehavior:promptBehavior
                        userId:userId
                         scope:nil
          extraQueryParameters:queryParams
                      tryCache:YES
               completionBlock:completionBlock];
}

//Gets an item from the cache, where userId may be nil. Raises error, if items for multiple users are present
//and user id is not specified.
-(ADTokenCacheStoreItem*) extractCacheItemWithKey: (ADTokenCacheStoreKey*) key
                                           userId: (NSString*) userId
                                            error: (ADAuthenticationError* __autoreleasing*) error
{
    if (!key || !self.tokenCacheStore)
    {
        return nil;//Nothing to return
    }
    
    ADTokenCacheStoreItem* extractedItem = nil;
    if (![NSString isStringNilOrBlank:userId])
    {
        extractedItem = [self.tokenCacheStore getItemWithKey:key userId:userId];
    }
    else
    {
        //No userId, check the cache for tokens for all users:
        NSArray* items = [self.tokenCacheStore getItemsWithKey:key];
        if (items.count > 1)
        {
            //More than one user token available in the cache, raise error to tell the developer to denote the desired user:
            ADAuthenticationError* adError  = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_MULTIPLE_USERS
                                                                                     protocolCode:nil
                                                                                     errorDetails:multiUserError];
            if (error)
            {
                *error = adError;
            }
            return nil;
        }
        else if (items.count == 1)
        {
            extractedItem = [items objectAtIndex:0];//Exactly one - just use it.
        }
    }
    return extractedItem;
}

//Checks the cache for item that can be used to get directly or indirectly an access token.
//Checks the multi-resource refresh tokens too.
-(ADTokenCacheStoreItem*) findCacheItemWithKey: (ADTokenCacheStoreKey*) key
                                        userId: (NSString*) userId
                                useAccessToken: (BOOL*) useAccessToken
                                         error: (ADAuthenticationError* __autoreleasing*) error
{
    if (!key || !self.tokenCacheStore)
    {
        return nil;//Nothing to return
    }
    ADAuthenticationError* localError;
    ADTokenCacheStoreItem* item = [self extractCacheItemWithKey:key userId:userId error:&localError];
    if (localError)
    {
        if (error)
        {
            *error = localError;
        }
        return nil;//Quick return if an error was detected.
    }
    
    if (item)
    {
        *useAccessToken = item.accessToken && !item.isExpired;
        if (*useAccessToken)
        {
            return item;
        }
        else if (![NSString isStringNilOrBlank:item.refreshToken])
        {
            return item;//Suitable direct refresh token found.
        }
        else
        {
            //We have a cache item that cannot be used anymore, remove it from the cache:
            [self.tokenCacheStore removeItemWithKey:key userId:userId];
        }
    }
    *useAccessToken = false;//No item with suitable access token exists
    
    if (![NSString isStringNilOrBlank:key.resource])
    {
        //The request came for specific resource. Try returning a multi-resource refresh token:
        ADTokenCacheStoreKey* broadKey = [ADTokenCacheStoreKey keyWithAuthority:self.authority
                                                                       resource:nil
                                                                       clientId:key.clientId
                                                                          error:&localError];
        if (!broadKey)
        {
            AD_LOG_WARN(@"Unexped error", localError.errorDetails);
            return nil;//Recover
        }
        ADTokenCacheStoreItem* broadItem = [self extractCacheItemWithKey:broadKey userId:userId error:&localError];
        if (localError)
        {
            if (error)
            {
                *error = localError;
            }
            return nil;
        }
        return broadItem;
    }
    return nil;//Nothing suitable
}

-(void) internalAcquireToken: (NSString*) resource
                    clientId: (NSString*) clientId
                 redirectUri: (NSURL*) redirectUri
              promptBehavior: (ADPromptBehavior) promptBehavior
                      userId: (NSString*) userId
                       scope: (NSString*) scope
        extraQueryParameters: (NSString*) queryParams
                    tryCache: (BOOL) tryCache /* set internally to avoid infinite recursion */
             completionBlock: (ADAuthenticationCallback)completionBlock
{
    THROW_ON_NIL_ARGUMENT(completionBlock);
    HANDLE_ARGUMENT(resource);

    //Check the cache:
    ADAuthenticationError* error;
    //We are explicitly creating a key first to ensure indirectly that all of the required arguments are correct.
    //This is the safest way to guarantee it, it will raise an error, if the the any argument is not correct:
    ADTokenCacheStoreKey* key = [ADTokenCacheStoreKey keyWithAuthority:self.authority resource:resource clientId:clientId error:&error];
    if (!key)
    {
        //If the key cannot be extracted, call the callback with the information:
        ADAuthenticationResult* result = [ADAuthenticationResult resultFromError:error];
        completionBlock(result);
        return;
    }
    
    if (tryCache && promptBehavior != AD_PROMPT_ALWAYS && self.tokenCacheStore)
    {
        //Cache should be used in this case:
        BOOL accessTokenUsable;
        ADTokenCacheStoreItem* cacheItem = [self findCacheItemWithKey:key userId:userId useAccessToken:&accessTokenUsable error:&error];
        if (error)
        {
            completionBlock([ADAuthenticationResult resultFromError:error]);
            return;
        }
        
        if (cacheItem)
        {
            //Found a promising item in the cache, try using it:
            [self attemptToUseCacheItem:cacheItem
                         useAccessToken:accessTokenUsable
                               resource:resource
                               clientId:clientId
                            redirectUri:redirectUri
                         promptBehavior:promptBehavior
                                 userId:userId
                   extraQueryParameters:queryParams
                        completionBlock:completionBlock];
            return; //The tryRefreshingFromCacheItem has taken care of the token obtaining
        }
    }
    
    if (promptBehavior == AD_PROMPT_NEVER)
    {
        //The cache lookup and refresh token attempt have been unsuccessful,
        //so credentials are needed to get an access token:
        ADAuthenticationError* error =
        [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_USER_INPUT_NEEDED
                                               protocolCode:nil
                                               errorDetails:credentialsNeeded];
        ADAuthenticationResult* result = [ADAuthenticationResult resultFromError:error];
        completionBlock(result);
        return;
    }
    
    dispatch_async([ADAuthenticationSettings sharedInstance].dispatchQueue, ^
                   {
                       //Get the code first:
                       [self requestCodeByResource:resource
                                          clientId:clientId
                                       redirectUri:redirectUri
                                             scope:scope
                                            userId:userId
                                           webView:self.webView
                                    promptBehavior:promptBehavior
                              extraQueryParameters:queryParams
                                        completion:^(NSString * code, ADAuthenticationError *error)
                        {
                            if (error)
                            {
                                ADAuthenticationResult* result = (AD_ERROR_USER_CANCEL == error.code) ? [ADAuthenticationResult resultFromCancellation] : [ADAuthenticationResult resultFromError:error];
                                completionBlock(result);
                            }
                            else
                            {
                                [self requestTokenByCode:code
                                                resource:resource
                                                clientId:clientId
                                             redirectUri:redirectUri
                                                   scope:scope
                                              completion:^(ADAuthenticationResult *result)
                                 {
                                     if (AD_SUCCEEDED == result.status)
                                     {
                                         [self updateCacheToResult:result cacheItem:nil withRefreshToken:nil];
                                     }
                                     completionBlock(result);
                                 }];
                            }
                        }];
                   });
}

-(void) acquireTokenByRefreshToken: (NSString*)refreshToken
                          clientId: (NSString*)clientId
                   completionBlock: (ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    [self internalAcquireTokenByRefreshToken:refreshToken
                                    clientId:clientId
                                    resource:nil
                                      userId:nil
                                   cacheItem:nil
                             completionBlock:completionBlock];
}

-(void) acquireTokenByRefreshToken:(NSString*)refreshToken
                          clientId:(NSString*)clientId
                          resource:(NSString*)resource
                   completionBlock:(ADAuthenticationCallback)completionBlock
{
    API_ENTRY;
    [self internalAcquireTokenByRefreshToken:refreshToken
                                    clientId:clientId
                                    resource:resource
                                      userId:nil
                                   cacheItem:nil
                             completionBlock:completionBlock];
}

//Stores the result in the cache. cacheItem parameter may be nil, if the result is successfull and contains
//the item to be stored.
-(void) updateCacheToResult: (ADAuthenticationResult*) result
                  cacheItem: (ADTokenCacheStoreItem*) cacheItem
           withRefreshToken: (NSString*) refreshToken
{
    THROW_ON_NIL_ARGUMENT(result);
    
    if (!self.tokenCacheStore)
        return;//No cache to update

    if (AD_SUCCEEDED == result.status)
    {
        THROW_ON_NIL_ARGUMENT(result.tokenCacheStoreItem);
        THROW_ON_NIL_EMPTY_ARGUMENT(result.tokenCacheStoreItem.resource);
        THROW_ON_NIL_EMPTY_ARGUMENT(result.tokenCacheStoreItem.accessToken);

        //In case of success we use explicitly the item that comes back in the result:
        cacheItem = result.tokenCacheStoreItem;
        if (result.multiResourceRefreshToken)
        {
            {
                NSString* logMessage = [NSString stringWithFormat:@"Storing multi-resource refresh token for authority: %@", self.authority];
                AD_LOG_VERBOSE(@"Token cache store", logMessage);
            }
            //If the server returned a multi-resource refresh token, we break
            //the item into two: one with the access token and no refresh token and
            //another one with the broad refresh token and no access token and no resource.
            //This breaking is useful for further updates on the cache and quick lookups
            ADTokenCacheStoreItem* multiRefreshTokenItem = [cacheItem copy];
            cacheItem.refreshToken = nil;
            
            multiRefreshTokenItem.accessToken = nil;
            multiRefreshTokenItem.resource = nil;
            multiRefreshTokenItem.expiresOn = nil;
            [self.tokenCacheStore addOrUpdateItem:multiRefreshTokenItem error:nil];
        }
        
        {
            NSString* logMessage = [NSString stringWithFormat:@"Storing access token for resource: %@", cacheItem.resource];
            AD_LOG_VERBOSE(@"Token cache store", logMessage);
        }
        [self.tokenCacheStore addOrUpdateItem:cacheItem error:nil];
    }
    else
    {
        if (AD_ERROR_INVALID_REFRESH_TOKEN == result.error.code)
        {//Bad refresh token. Remove it from the cache:
            THROW_ON_NIL_ARGUMENT(cacheItem);
            THROW_ON_NIL_EMPTY_ARGUMENT(cacheItem.resource);
            THROW_ON_NIL_EMPTY_ARGUMENT(refreshToken);
            
            BOOL removed = NO;
            //The refresh token didn't work. We need to clear this refresh item from the cache.
            ADTokenCacheStoreKey* exactKey = [cacheItem extractKeyWithError:nil];
            if (exactKey)
            {
                ADTokenCacheStoreItem* existing = [self.tokenCacheStore getItemWithKey:exactKey userId:cacheItem.userInformation.userId];
                if ([refreshToken isEqualToString:existing.refreshToken])
                {
                    {
                        NSString* logMessage = [NSString stringWithFormat:@"Removing cache for resource: %@", cacheItem.resource];
                        AD_LOG_VERBOSE(@"Token cache store", logMessage);
                    }
                    [self.tokenCacheStore removeItemWithKey:exactKey userId:existing.userInformation.userId];
                    removed = YES;
                }
            }
            
            if (!removed)
            {
                //Now try finding a broad refresh token in the cache and remove it accordingly
                ADTokenCacheStoreKey* broadKey = [ADTokenCacheStoreKey keyWithAuthority:self.authority resource:nil clientId:cacheItem.clientId error:nil];
                if (broadKey)
                {
                    ADTokenCacheStoreItem* broadItem = [self.tokenCacheStore getItemWithKey:broadKey userId:cacheItem.userInformation.userId];
                    if (broadItem && [refreshToken isEqualToString:broadItem.refreshToken])
                    {
                        {
                            NSString* logMessage = [NSString stringWithFormat:@"Removing multi-resource refresh token for authority: %@", self.authority];
                            AD_LOG_VERBOSE(@"Token cache store", logMessage);
                        }
                        [self.tokenCacheStore removeItemWithKey:broadKey userId:cacheItem.userInformation.userId];
                    }
                }
            }
        }
    }
}

//Obtains an access token from the passed refresh token. If "cacheItem" is passed, updates it with the additional
//information and updates the cache:
-(void) internalAcquireTokenByRefreshToken: (NSString*) refreshToken
                                  clientId: (NSString*) clientId
                                  resource: (NSString*) resource
                                    userId: (NSString*) userId
                                 cacheItem: (ADTokenCacheStoreItem*) cacheItem
                           completionBlock: (ADAuthenticationCallback)completionBlock
{
    HANDLE_ARGUMENT(refreshToken);
    HANDLE_ARGUMENT(clientId);
    {
        NSString* logMessage = [NSString stringWithFormat:@"Resource: %@", resource];
        AD_LOG_VERBOSE(@"Attempting to acquire an access token from refresh token.", logMessage);
    }
    //Fill the data for the token refreshing:
    NSMutableDictionary *request_data = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                         OAUTH2_REFRESH_TOKEN, OAUTH2_GRANT_TYPE,
                                         refreshToken, OAUTH2_REFRESH_TOKEN,
                                         clientId, OAUTH2_CLIENT_ID,
                                         nil];
    
    if (![NSString isStringNilOrBlank:resource])
    {
        [request_data setObject:resource forKey:OAUTH2_RESOURCE];
    }
    
    // Append platform_id if it has been set
    if ( [ADAuthenticationSettings sharedInstance].platformId != nil )
    {
        [request_data setObject:[ADAuthenticationSettings sharedInstance].platformId forKey:@"platform_id"];
    }
    
    dispatch_async([ADAuthenticationSettings sharedInstance].dispatchQueue, ^
                   {
                       NSString* log = [NSString stringWithFormat:@"Client id: '%@'; resource: '%@'; user:'%@'", clientId, resource, userId];
                       AD_LOG_INFO(@"Sending request for refreshing token.", log);
                       [self request:self.authority requestData:request_data completion:^(NSDictionary *response)
                        {
                            ADTokenCacheStoreItem* resultItem = (cacheItem) ? cacheItem : [ADTokenCacheStoreItem new];
                            
                            //Always ensure that the cache item has all of these set, especially in the broad token case, where the passed item
                            //may have empty "resource" property:
                            resultItem.resource = resource;
                            resultItem.clientId = clientId;
                            resultItem.authority = self.authority;
                            
                            
                            ADAuthenticationResult *result = [self processTokenResponse:response forItem:resultItem fromRefresh:YES];
                            if (cacheItem)//The request came from the cache item, update it:
                            {
                                [self updateCacheToResult:result
                                                cacheItem:resultItem
                                         withRefreshToken:refreshToken];
                            }
                            
                            completionBlock(result);
                        }];
                   });
}

//Understands and processes the access token response:
- (ADAuthenticationResult *)processTokenResponse: (NSDictionary *)response
                                         forItem: (ADTokenCacheStoreItem*)item
                                     fromRefresh: (BOOL) fromRefreshTokenWorkflow
{
    THROW_ON_NIL_ARGUMENT(response);
    THROW_ON_NIL_ARGUMENT(item);
    AD_LOG_VERBOSE(@"Token extraction", @"Attempt to extract the data from the server response.");
    
    ADAuthenticationError* error = [self errorFromDictionary:response errorCode:(fromRefreshTokenWorkflow) ? AD_ERROR_INVALID_REFRESH_TOKEN : AD_ERROR_AUTHENTICATION];
    if (error)
    {
        return [ADAuthenticationResult resultFromError:error];
    }
    
    NSString* accessToken = [response objectForKey:OAUTH2_ACCESS_TOKEN];
    if (![NSString isStringNilOrBlank:accessToken])
    {
        item.authority = self.authority;
        item.accessToken = accessToken;
        
        // Token response
        id      expires_in = [response objectForKey:@"expires_in"];
        NSDate *expires    = nil;
        
        if ( expires_in != nil )
        {
            if ( [expires_in isKindOfClass:[NSString class]] )
            {
                NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
                
                expires = [NSDate dateWithTimeIntervalSinceNow:[formatter numberFromString:expires_in].longValue];
            }
            else if ( [expires_in isKindOfClass:[NSNumber class]] )
            {
                expires = [NSDate dateWithTimeIntervalSinceNow:((NSNumber *)expires_in).longValue];
            }
            else
            {
                NSString* log = [NSString stringWithFormat:@"The response value for the access token expiration cannot be parsed: %@", expires];
                AD_LOG_WARN(@"Unparsable time", log);
                // Unparseable, use default value
                expires = [NSDate dateWithTimeIntervalSinceNow:3600.0];//1 hour
            }
        }
        else
        {
            AD_LOG_WARN(@"Missing expiration time.", @"The server did not return the expiration time for the access token.");
            expires = [NSDate dateWithTimeIntervalSinceNow:3600.0];//Assume 1hr expiration
        }
        
        item.accessTokenType = [response objectForKey:OAUTH2_TOKEN_TYPE];
        item.expiresOn       = expires;
        item.refreshToken    = [response objectForKey:OAUTH2_REFRESH_TOKEN];
        NSString* resource   = [response objectForKey:OAUTH2_RESOURCE];
        BOOL multiResourceRefreshToken = NO;
        if (![NSString isStringNilOrBlank:resource])
        {
            if (item.resource && ![item.resource isEqualToString:resource])
            {
                NSString* message = [NSString stringWithFormat:@"Expected resource: '%@'; Server returned: '%@'", item.resource, resource];
                AD_LOG_WARN(@"Wrong resource returned by the server.", message);
            }
            //Currently, if the server has returned a "resource" parameter and we have a refresh token,
            //this token is a multi-resource refresh token:
            multiResourceRefreshToken = ![NSString isStringNilOrBlank:item.refreshToken];
        }
        
        NSString* idToken = [response objectForKey:OAUTH2_ID_TOKEN];
        if (idToken)
        {
            ADUserInformation* userInfo = [ADUserInformation userInformationWithIdToken:idToken error:nil];
            if (userInfo)
            {
                item.userInformation = userInfo;
            }
        }
        
        return [ADAuthenticationResult resultFromTokenCacheStoreItem:item multiResourceRefreshToken:multiResourceRefreshToken];
    }
    
    //No access token and no error, we assume that there was another kind of error (connection, server down, etc.).
    //Note that for security reasons we log only the keys, not the values returned by the user:
    NSString* errorMessage = [NSString stringWithFormat:@"The server returned without providing an error. Keys returned: %@", [response allKeys]];
    error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_AUTHENTICATION
                                                   protocolCode:nil
                                                   errorDetails:errorMessage];
    return [ADAuthenticationResult resultFromError:error];
}

//Ensures that a single UI login dialog can be requested at a time.
//Returns true if successfully acquired the lock. If not, calls the callback with
//the error and returns false.
-(BOOL) takeExclusionLockWithCallback: (ADAuthorizationCodeCallback) completionBlock
{
    THROW_ON_NIL_ARGUMENT(completionBlock);
    if ( !OSAtomicCompareAndSwapInt( 0, 1, &sDialogInProgress) )
    {
        NSString* message = @"The user is currently prompted for credentials as result of another acquireToken request. Please retry the acquireToken call later.";
        ADAuthenticationError* error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_USER_PROMPTED
                                                                              protocolCode:nil
                                                                              errorDetails:message];
        completionBlock(nil, error);
        return NO;
    }
    return YES;
}

//Attempts to release the lock. Logs warning if the lock was already released.
-(void) releaseExclusionLock
{
    if ( !OSAtomicCompareAndSwapInt( 1, 0, &sDialogInProgress) )
    {
        AD_LOG_WARN(@"UI Locking", @"The UI lock has already been released.")
    }
}

//Generates the query string, encoding the state:
-(NSString*) queryStringFromResource: (NSString*) resource
                            clientId: (NSString*) clientId
                         redirectUri: (NSURL*) redirectUri
                               scope: (NSString*) scope /* for future use */
                              userId: (NSString*) userId
                         requestType: (NSString*) requestType
                      promptBehavior: (ADPromptBehavior) promptBehavior
                extraQueryParameters: (NSString*) queryParams
{
    NSString *state    = [self encodeProtocolStateWithResource:resource scope:scope];
    // Start the web navigation process for the Implicit grant profile.
    NSString *startUrl = [NSString stringWithFormat:@"%@?%@=%@&%@=%@&%@=%@&%@=%@&%@=%@",
                          [self.authority stringByAppendingString:OAUTH2_AUTHORIZE_SUFFIX],
                          OAUTH2_RESPONSE_TYPE, requestType,
                          OAUTH2_CLIENT_ID, [clientId adUrlFormEncode],
                          OAUTH2_RESOURCE, [resource adUrlFormEncode],
                          OAUTH2_REDIRECT_URI, [[redirectUri absoluteString] adUrlFormEncode],
                          OAUTH2_STATE, state];
    NSString* platformId = [ADAuthenticationSettings sharedInstance].platformId;
    if (![NSString isStringNilOrBlank:platformId])
    {
        startUrl = [startUrl stringByAppendingString:[NSString stringWithFormat:@"&%@=%@", OAUTH2_PLATFORM_ID, [platformId adUrlFormEncode]]];
    }
    if (![NSString isStringNilOrBlank:userId])
    {
        startUrl = [startUrl stringByAppendingString:[NSString stringWithFormat:@"&%@=%@", OAUTH2_LOGIN_HINT, [userId adUrlFormEncode]]];
    }
    if (AD_PROMPT_ALWAYS == promptBehavior)
    {
        //Force the server to ignore cookies, by specifying explicitly the prompt behavior:
        startUrl = [startUrl stringByAppendingString:[NSString stringWithFormat:@"&prompt=login"]];
    }
    if (![NSString isStringNilOrBlank:queryParams])
    {//Append the additional query parameters if specified:
        queryParams = queryParams.trimmedString;
        
        //Add the '&' for the additional params if not there already:
        startUrl = [queryParams hasPrefix:@"&"] ? [startUrl stringByAppendingString:queryParams]
                                                : [startUrl stringByAppendingString:[NSString stringWithFormat:@"&%@", queryParams]];
    }
    
    return startUrl;
}

//Obtains a protocol error from the response:
-(ADAuthenticationError*) errorFromDictionary: (NSDictionary*) dictionary
                                    errorCode: (ADErrorCode) errorCode
{
    //First check for explicit OAuth2 protocol error:
    NSString* serverOAuth2Error = [dictionary objectForKey:OAUTH2_ERROR];
    if (![NSString isStringNilOrBlank:serverOAuth2Error])
    {
        NSString* errorDetails = [dictionary objectForKey:OAUTH2_ERROR_DESCRIPTION];
        // Error response from the server
        return [ADAuthenticationError errorFromAuthenticationError:errorCode
                                                       protocolCode:serverOAuth2Error
                                                       errorDetails:(errorDetails) ? errorDetails : [NSString stringWithFormat:serverError, serverOAuth2Error]];
    }
    //In the case of more generic error, e.g. server unavailable, DNS error or no internet connection, the error object will be directly placed in the dictionary:
    return [dictionary objectForKey:AUTH_NON_PROTOCOL_ERROR];
}

//Ensures that the state comes back in the response:
-(BOOL) verifyStateFromDictionary: (NSDictionary*) dictionary
{
    NSDictionary *state = [self.class decodeProtocolState:[dictionary objectForKey:OAUTH2_STATE]];
    if (state.count != 0)
    {
        NSString *authorizationServer = [state objectForKey:@"a"];
        NSString *resource            = [state objectForKey:@"r"];
        
        if (![NSString isStringNilOrBlank:authorizationServer] && ![NSString isStringNilOrBlank:resource])
        {
            NSString* log = [NSString stringWithFormat:@"The authorization server returned the following state: %@", state];
            AD_LOG_VERBOSE(@"State", log);
            return YES;
        }
    }
    NSString* log = [NSString stringWithFormat:@"Missing or invalid state returned: %@", state];
    AD_LOG_WARN(@"State error", log);
    return NO;
}

//Requests an OAuth2 code to be used for obtaining a token:
-(void) requestCodeByResource: (NSString*) resource
                     clientId: (NSString*) clientId
                  redirectUri: (NSURL*) redirectUri
                        scope: (NSString*) scope /*for future use */
                       userId: (NSString*) userId
                      webView: (WebViewType *) webView
               promptBehavior: (ADPromptBehavior) promptBehavior
         extraQueryParameters: (NSString*) queryParams
                   completion: (ADAuthorizationCodeCallback) completionBlock
{
    THROW_ON_NIL_ARGUMENT(completionBlock);
    {
        NSString* logMessage = [NSString stringWithFormat:@"Requesting authorization code for resource: %@", resource];
        AD_LOG_VERBOSE(@"Requesting authorization code.", logMessage);
    }
    if (![self takeExclusionLockWithCallback:completionBlock])
    {
        return;
    }
    ADAuthenticationSettings* settings = [ADAuthenticationSettings sharedInstance];
    NSString* startUrl = [self queryStringFromResource:resource
                                              clientId:clientId
                                           redirectUri:redirectUri
                                                 scope:scope
                                                userId:userId
                                           requestType:OAUTH2_CODE
                                        promptBehavior:promptBehavior
                                  extraQueryParameters:queryParams];
    
    [[WebAuthenticationBroker sharedInstance] start:[NSURL URLWithString:startUrl]
                                                end:[NSURL URLWithString:[redirectUri absoluteString]]
                                            ssoMode:settings.singleSignOn
                                            webView:webView
                                         fullScreen:settings.enableFullScreen
                                         completion:^( ADAuthenticationError *error, NSURL *end )
     {
         [self releaseExclusionLock]; // Allow other operations that use the UI for credentials.
         
         NSString* code = nil;
         if (!error)
         {
             //Try both the URL and the fragment parameters:
             NSDictionary *parameters = [end fragmentParameters];
             if ( parameters.count == 0 )
             {
                 parameters = [end queryParameters];
             }
             
             //OAuth2 error may be passed by the server:
             error = [self errorFromDictionary:parameters errorCode:AD_ERROR_AUTHENTICATION];
             if (!error)
             {
                 //Note that we do not enforce the state, just log it:
                 [self verifyStateFromDictionary:parameters];
                 code = [parameters objectForKey:OAUTH2_CODE];
                 if ([NSString isStringNilOrBlank:code])
                 {
                     error = [ADAuthenticationError errorFromAuthenticationError:AD_ERROR_AUTHENTICATION
                                                                    protocolCode:nil
                                                                    errorDetails:@"The authorization server did not return a valid authorization code."];
                 }
             }
         }
         
         completionBlock(code, error);
     }];
}


// Generic OAuth2 Authorization Request, obtains a token from an authorization code.
- (void)requestTokenByCode: (NSString *) code
                  resource: (NSString *) resource
                  clientId: (NSString*) clientId
               redirectUri: (NSURL*) redirectUri
                     scope: (NSString*) scope
                completion: (ADAuthenticationCallback) completionBlock
{
    THROW_ON_NIL_EMPTY_ARGUMENT(code);
    {
        NSString* logMessage = [NSString stringWithFormat:@"Requesting token by authorization code for resource: %@", resource];
        AD_LOG_VERBOSE(@"Requesting token from authorization code.", logMessage);
    }
    
    //Fill the data for the token refreshing:
    NSMutableDictionary *request_data = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                         OAUTH2_AUTHORIZATION_CODE, OAUTH2_GRANT_TYPE,
                                         code, OAUTH2_CODE,
                                         clientId, OAUTH2_CLIENT_ID,
                                         [redirectUri absoluteString], OAUTH2_REDIRECT_URI,
                                         nil];
    
    // Append platform_id if it has been set
    if ( [ADAuthenticationSettings sharedInstance].platformId != nil )
    {
        [request_data setObject:[ADAuthenticationSettings sharedInstance].platformId forKey:OAUTH2_PLATFORM_ID];
    }
    
    [self request:self.authority requestData:request_data completion:^(NSDictionary *response) {
        //Prefill the known elements in the item. These can be overridden by the response:
        ADTokenCacheStoreItem* item = [ADTokenCacheStoreItem new];
        item.resource = resource;
        item.clientId = clientId;
        completionBlock([self processTokenResponse:response forItem:item fromRefresh:NO]);
    }];
}

// Performs an OAuth2 token request using the supplied request dictionary and executes the completion block
// If the request generates an HTTP error, the method adds details to the "error" parameters of the dictionary.
- (void)request:(NSString *)authorizationServer requestData:(NSDictionary *)request_data completion:( void (^)(NSDictionary *) )completionBlock
{
    // Generate a client-request-id
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidString = (__bridge_transfer NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    
    NSString* endPoint = [authorizationServer stringByAppendingString:OAUTH2_TOKEN_SUFFIX];
    NSString* log = [NSString stringWithFormat:@"Sending POST request to %@ with client-request-id %@", endPoint, uuidString];
    AD_LOG_VERBOSE(@"POST request", log);
    
    HTTPWebRequest *webRequest = [[HTTPWebRequest alloc] initWithURL:[NSURL URLWithString:endPoint]];
    
    webRequest.method = HTTPPost;
    [webRequest.headers setObject:@"application/json" forKey:@"Accept"];
    [webRequest.headers setObject:@"application/x-www-form-urlencoded" forKey:@"Content-Type"];
    [webRequest.headers setObject:uuidString forKey:@"client-request-id"];
    
    webRequest.body = [[request_data URLFormEncode] dataUsingEncoding:NSUTF8StringEncoding];
    
    [webRequest send:^( NSError *error, HTTPWebResponse *webResponse ) {
        // Request completion callback
        NSDictionary *response = nil;
        
        if ( error == nil )
        {
            switch (webResponse.statusCode)
            {
                case 200:
                case 400:
                case 401:
                    {
                        NSError   *jsonError  = nil;
                        id         jsonObject = [NSJSONSerialization JSONObjectWithData:webResponse.body options:0 error:&jsonError];
                    
                        if ( nil != jsonObject && [jsonObject isKindOfClass:[NSDictionary class]] )
                        {
                            // Load the response
                            response = (NSDictionary *)jsonObject;
                        }
                        else
                        {
                            // Unrecognized JSON response
                            AD_LOG_WARN(@"JSON deserialization", jsonError.localizedDescription);
                            NSMutableDictionary *mutableResponse = [[NSMutableDictionary alloc] initWithCapacity:1];
                            [mutableResponse setObject:[ADAuthenticationError errorFromNSError:jsonError errorDetails:jsonError.localizedDescription]
                                                forKey:AUTH_NON_PROTOCOL_ERROR];
                            response = mutableResponse;
                        }
                    }
                    break;
                default:
                    {
                        // Request failure
                        NSString* logMessage = [NSString stringWithFormat:@"Server HTTP Status %ld", (long)webResponse.statusCode];
                        NSString* errorData = [NSString stringWithFormat:@"Server HTTP Response %@", [[NSString alloc] initWithData:webResponse.body encoding:NSUTF8StringEncoding]];
                        AD_LOG_WARN(logMessage, errorData);
                        
                        //Now add the information to the dictionary, so that the parser can extract it:
                        NSMutableDictionary *mutableResponse = [[NSMutableDictionary alloc] initWithCapacity:1];
                        [mutableResponse setObject:[ADAuthenticationError errorFromAuthenticationError:AD_ERROR_AUTHENTICATION protocolCode:nil errorDetails:errorData]
                                            forKey:AUTH_NON_PROTOCOL_ERROR];
                        
                        response = mutableResponse;
                    }
            }
        }
        else
        {
            AD_LOG_WARN(@"System error while making request.", error.description);
            // System error
            NSMutableDictionary *mutableResponse = [[NSMutableDictionary alloc] initWithCapacity:1];
            [mutableResponse setObject:[ADAuthenticationError errorFromNSError:error errorDetails:error.localizedDescription]
                                forKey:AUTH_NON_PROTOCOL_ERROR];

            
            response = mutableResponse;
        }
        
        completionBlock( response );
    }];
}

// Verify we are running on the main thread and abort with a message otherwise
+ (void)assertMainThread:(NSString *)message
{
    if (![[NSThread currentThread] isEqual:[NSThread mainThread]])
    {
        NSAssert(false, message);
        @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:message userInfo:nil];
    }
}

// Decodes the state parameter from a protocol message
+ (NSDictionary *)decodeProtocolState:(NSString *)encodedState
{
    return [NSDictionary URLFormDecode:[encodedState adBase64UrlDecode]];
}

// Encodes the state parameter for a protocol message
- (NSString *)encodeProtocolStateWithResource:(NSString *)resource scope:(NSString *)scope
{
    return [[[NSMutableDictionary dictionaryWithObjectsAndKeys:self.authority, @"a", resource, @"r", scope, @"s", nil]
             URLFormEncode] adBase64UrlEncode];
}




@end

