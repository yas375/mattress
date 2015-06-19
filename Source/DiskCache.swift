//
//  DiskCache.swift
//  Mattress
//
//  Created by David Mauro on 11/12/14.
//  Copyright (c) 2014 BuzzFeed. All rights reserved.
//

/**
    DiskCache is a NSURLCache replacement that will store
    and retreive NSCachedURLResponses to disk.
*/

import Foundation
import UIKit

class DiskCache {
    /**
        Keys used to store properties in the plist.
    */
    enum DictionaryKeys: String {
        case maxCacheSize = "maxCacheSize"
        case requestsFilenameArray = "requestsFilenameArray"
    }

    // MARK: - Properties
    var isAtLeastiOS8: Bool {
        struct Static {
            static var onceToken : dispatch_once_t = 0
            static var value: Bool = false
        }
        dispatch_once(&Static.onceToken) {
            Static.value = (UIDevice.currentDevice().systemVersion as NSString).doubleValue >= 8.0
        }
        return Static.value
    }

    private let path: String
    private let searchPathDirectory: NSSearchPathDirectory
    private let maxCacheSize: Int
    
    private let lockObject = NSObject()
    
    var currentSize = 0
    var requestCaches: [String] = []

    // Mark: - Instance methods

    /**
        Initializes a new DiskCache
    
        :param: path The path of the location on disk that should be used
            to store requests. This MUST be unique for each DiskCache instance. Otherwise you will have hard to debug crashes.
        :param: searchPathDirectory The NSSearchPathDirectory that should be
            used to find the location at which to store requests.
        :param: maxCacheSize The size limit of this diskCache. When the size
            of the requests exceeds this amount, older requests will be removed.
            No requests that are larger than this size will even attempt to be
            stored.
    */
    init(path: String?, searchPathDirectory: NSSearchPathDirectory, maxCacheSize: Int) {
        self.path = path ?? "mattress"
        self.searchPathDirectory = searchPathDirectory
        self.maxCacheSize = maxCacheSize
        loadPropertiesFromDisk()
    }

    /**
        Load appropriate properties from the plist to restore
        this cache from disk.
    */
    private func loadPropertiesFromDisk() {
        synchronized(lockObject) { () -> Void in
            if let plistPath = self.diskPathForPropertyList()?.path {
                if !NSFileManager.defaultManager().fileExistsAtPath(plistPath) {
                    self.persistPropertiesToDisk()
                } else {
                    if let dict = NSDictionary(contentsOfFile: plistPath) {
                        if let currentSize = dict.valueForKey(DictionaryKeys.maxCacheSize.rawValue) as? Int {
                            self.currentSize = currentSize
                        }
                        if let requestCaches = dict.valueForKey(DictionaryKeys.requestsFilenameArray.rawValue) as? [String] {
                            self.requestCaches = requestCaches
                        }
                    }
                }
            }
        }
    }

    /**
        Save appropriate properties to a plist to save
        this cache to disk.
    */
    private func persistPropertiesToDisk() {
        synchronized(lockObject) { () -> Void in
            if let plistPath = self.diskPathForPropertyList()?.path {
                let dict = self.dictionaryForCache()
                dict.writeToFile(plistPath, atomically: true)
            }
            return
        }
    }

    func clearCache() {
        if let path = diskPath()?.path {
            NSFileManager.defaultManager().removeItemAtPath(path, error: nil)
        }
    }

    /**
        This will keep removing the oldest request until our
        currentSize is not greater than the maxCacheSize.
    */
    private func trimCacheIfNeeded() {
        while currentSize > maxCacheSize && !requestCaches.isEmpty {
            let fileName = requestCaches.removeAtIndex(0)
            if let path = diskPathForRequestCacheNamed(fileName)?.path {
                if let
                    attributes = NSFileManager.defaultManager().attributesOfItemAtPath(path, error: nil) as? [String: AnyObject],
                    fileSize = attributes[NSFileSize] as? NSNumber
                {
                        let size = fileSize.integerValue
                        currentSize -= size
                }
                NSFileManager.defaultManager().removeItemAtPath(path, error: nil)
            }
        }
    }

    /**
        Create an NSDictionary that will be used to store
        this diskCache's properties to disk.
    */
    private func dictionaryForCache() -> NSDictionary {
        var dict = NSMutableDictionary()
        dict.setValue(currentSize, forKey: DictionaryKeys.maxCacheSize.rawValue)
        dict.setValue(requestCaches, forKey: DictionaryKeys.requestsFilenameArray.rawValue)
        return NSDictionary(dictionary: dict)
    }

    /**
        storeCachedResponse:forRequest: functions much like NSURLCache's
        similarly named method, storing a response and request to disk only.
    
        :param: cachedResponse an NSCachedURLResponse to persist to disk.
        :param: forRequest an NSURLRequest to associate the cachedResponse with.
    
        :returns: A Bool representing whether or not we successfully
            stored the response to disk.
    */
    func storeCachedResponse(cachedResponse: NSCachedURLResponse, forRequest request: NSURLRequest) -> Bool {
        var success = false
        
        synchronized(lockObject) { () -> Void in
            if let hash = self.hashForRequest(request) {
                if self.isAtLeastiOS8 {
                    success = self.saveObject(cachedResponse, withHash: hash)
                } else {
                    success = self.storeCachedResponsePieces(cachedResponse, withHash: hash)
                }
            }
        }
        
        return success
    }

    /**
        This will store components of the NSCachedURLResponse to disk each
        individually to work around iOS 7 not properly storing the response
        to disk with it's data and userInfo.
    
        NOTE: Storage policy is not stored because it is irrelevant to Mattress
        cached responses.

        :param: cachedResponse an NSCachedURLResponse to persist to disk.
        :param: hash The hash associated with the NSCachedURLResponse.

        :returns: A Bool representing whether or not we successfully
            stored the response to disk.
    */
    private func storeCachedResponsePieces(cachedResponse: NSCachedURLResponse, withHash hash: String) -> Bool {
        var success = true
        synchronized(lockObject) { () -> Void in
            let responseHash = self.hashForResponseFromHash(hash)
            success = success && self.saveObject(cachedResponse.response, withHash: responseHash)
            let dataHash = self.hashForDataFromHash(hash)
            success = success && self.saveObject(cachedResponse.data, withHash: dataHash)
            if let userInfo = cachedResponse.userInfo {
                if !userInfo.isEmpty {
                    let userInfoHash = self.hashForUserInfoFromHash(hash)
                    success = success && self.saveObject(userInfo, withHash: userInfoHash)
                }
            }
        }
        return success
    }

    /**
        Saves an archived object's data to disk with the hash it
        should be associated with. This will only store the request
        if it could fit in our max cache size, and will empty out
        older cached items if it needs to to make room.
    
        :param: data The data of the archived root object.
        :param: hash The hash associated with that object.
    
        :returns: A Bool indicating that the saves were successful.
    */
    private func saveObject(object: NSCoding, withHash hash: String) -> Bool {
        var success = false
        
        synchronized(lockObject) { () -> Void in
            let data = NSKeyedArchiver.archivedDataWithRootObject(object)
            if var path = self.diskPathForRequestCacheNamed(hash)?.path {
                if count(path) > 255 {
                    //path =
                    
                }
                if data.length < self.maxCacheSize {
                    self.currentSize += data.length
                    var index = -1
                    for i in 0..<self.requestCaches.count {
                        if self.requestCaches[i] == hash {
                            index = i
                            break
                        }
                    }
                    if index != -1 {
                        self.requestCaches.removeAtIndex(index)
                    }
                    self.requestCaches.append(hash)
                    self.trimCacheIfNeeded()
                    self.persistPropertiesToDisk()
                    var error: NSError?
                    success = data.writeToFile(path, options: .allZeros, error: &error)
                    if let error = error {
                        NSLog("Error writing request to disk: \(error)")
                    }
                }
            }
        }
    
        return success
    }

    /**
        cachedResponseForRequest: functions much like NSURLCache's
        method of the same signature. An NSCachedURLResponse associated
        with the specified NSURLRequest will be returned.
    */
    func cachedResponseForRequest(request: NSURLRequest) -> NSCachedURLResponse? {
        var response: NSCachedURLResponse?
        
        synchronized(lockObject) { () -> Void in

            if let path = self.diskPathForRequest(request)?.path {
                if self.isAtLeastiOS8 {
                    response = NSKeyedUnarchiver.unarchiveObjectWithFile(path) as? NSCachedURLResponse
                } else {
                    response = self.cachedResponseFromPiecesForRequest(request)
                }
            }
        }

        return response
    }

    /**
        This will simply check if a response exists in the cache for the
        specified request.
    */
    internal func hasCachedResponseForRequest(request: NSURLRequest) -> Bool {

        if let path = self.diskPathForRequest(request)?.path {
            return NSFileManager.defaultManager().fileExistsAtPath(path)
        }
        return false
    }

    /**
        Will create the cachedResponse from its response, data and
        userInfo. This is only used to workaround the bug in iOS 7
        preventing us from just saving the cachedResponse itself.
    */
    private func cachedResponseFromPiecesForRequest(request: NSURLRequest) -> NSCachedURLResponse? {
        var cachedResponse: NSCachedURLResponse? = nil
        
        synchronized(lockObject) { () -> Void in

            var response: NSURLResponse? = nil
            var data: NSData? = nil
            var userInfo: [NSObject : AnyObject]? = nil

            if let basePath = self.diskPathForRequest(request)?.path {
                let responsePath = self.hashForResponseFromHash(basePath)
                response = NSKeyedUnarchiver.unarchiveObjectWithFile(responsePath) as? NSURLResponse
                let dataPath = self.hashForDataFromHash(basePath)
                data = NSKeyedUnarchiver.unarchiveObjectWithFile(dataPath) as? NSData
                let userInfoPath = self.hashForUserInfoFromHash(basePath)
                userInfo = NSKeyedUnarchiver.unarchiveObjectWithFile(userInfoPath) as? [NSObject : AnyObject]
            }

            if let
                response = response,
                data = data
            {
                cachedResponse = NSCachedURLResponse(response: response, data: data, userInfo: userInfo, storagePolicy: .Allowed)
            }
        }

        return cachedResponse
    }

    /**
        hasCacheForRequest: returns a Bool indicating whether
        this diskCache has a cachedResponse associated with the
        specified NSURLRequest.
    */
    func hasCacheForRequest(request: NSURLRequest) -> Bool {
        if let hash = hashForRequest(request) {
            for requestHash in requestCaches {
                if hash == requestHash {
                    return true
                }
            }
        }
        return false
    }

    /**
        Returns the path where we should store our plist.
    */
    func diskPathForPropertyList() -> NSURL? {
        var url: NSURL?
        let filename = "diskCacheInfo.plist"
        if let baseURL = diskPath() {
            url = NSURL(string: filename, relativeToURL: baseURL)
        }
        return url
    }

    /**
        Returns the path where we should store a cache
        with the specified filename.
    */
    private func diskPathForRequestCacheNamed(name: String) -> NSURL? {
        var url: NSURL?
        if let baseURL = diskPath() {
            url = NSURL(string: name, relativeToURL: baseURL)
        }
        return url
    }

    /**
        Returns the path where a response should be stored
        for a given NSURLRequest.
    */
    func diskPathForRequest(request: NSURLRequest) -> NSURL? {
        var url: NSURL?
        if let
            hash = hashForRequest(request),
            baseURL = diskPath()
        {
            NSLog("stuff not nil")
            url = NSURL(string: hash, relativeToURL: baseURL)
        }
        return url
    }

    /**
        Return the path that should be used as the baseURL for
        all paths associated with this diskCache.
    */
    private func diskPath() -> NSURL? {
        var url: NSURL?
        if let
            baseURL = NSFileManager.defaultManager().URLForDirectory(searchPathDirectory,
                inDomain: .UserDomainMask, appropriateForURL: nil, create: false, error: nil),
            fileURL = NSURL(string: path, relativeToURL: baseURL),
            fileURLString = fileURL.absoluteString
        {
            var isDir : ObjCBool = false
            if !NSFileManager.defaultManager().fileExistsAtPath(fileURLString, isDirectory: &isDir) {
                NSFileManager.defaultManager().createDirectoryAtURL(fileURL,
                    withIntermediateDirectories: true, attributes: nil, error: nil)
            }
            url = fileURL
        }
        return url
    }

    /**
        Returns the hash/filename that should be used for
        a given NSURLRequest.
    */
    func hashForRequest(request: NSURLRequest) -> String? {
        if let urlString = request.URL?.absoluteString {
            return hashForURLString(urlString)
        }
        return nil
    }

    /**
        Returns the hash/filename for the response associated with
        the hash for a request. This is only used as an iOS 7
        workaround.
    */
    func hashForResponseFromHash(hash: String) -> String {
        return "\(hash)_response"
    }

    /**
        Returns the hash/filename for the data associated with
        the hash for a request. This is only used as an iOS 7
        workaround.
    */
    func hashForDataFromHash(hash: String) -> String {
        return "\(hash)_data"
    }

    /**
        Returns the hash/filename for the userInfo associated with
        the hash for a request. This is only used as an iOS 7
        workaround.
    */
    func hashForUserInfoFromHash(hash: String) -> String {
        return "\(hash)_userInfo"
    }

    /**
        Returns the hash/filename that should be used for
        a given the URL absoluteString of a request.
    */
    func hashForURLString(string: String) -> String? {
        return string.MD5()
    }
}