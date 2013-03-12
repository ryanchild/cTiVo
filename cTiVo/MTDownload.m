//
//  MTDownload.m
//  cTiVo
//
//  Created by Hugh Mackworth on 2/26/13.
//  Copyright (c) 2013 Scott Buchanan. All rights reserved.
//


#import "MTProgramTableView.h"
#import "MTiTunes.h"
#import "MTTiVoManager.h"
#import "MTDownload.h"

@interface MTDownload () {
	
	NSFileHandle    *downloadFileHandle,
	*decryptLogFileHandle,
	*decryptLogFileReadHandle,
	*commercialFileHandle,
	*commercialLogFileHandle,
	*commercialLogFileReadHandle,
	*captionFileHandle,
	*captionLogFileHandle,
	*captionLogFileReadHandle,
	*encodeFileHandle,
	*encodeLogFileHandle,
	*encodeLogFileReadHandle,
	*encodeErrorFileHandle,
	*bufferFileReadHandle,
	*bufferFileWriteHandle;
	
	NSString		*decryptFilePath,
	*decryptLogFilePath,
	*encodeLogFilePath,
	*encodeErrorFilePath,
	*commercialFilePath,
	*commercialLogFilePath,
	*captionFilePath,
	*captionLogFilePath;
	
    double dataDownloaded;
    NSTask *encoderTask, *decrypterTask, *commercialTask, *captionTask, *apmTask;
	NSURLConnection *activeURLConnection;
	NSPipe *pipe1, *pipe2;
	BOOL volatile writingData, downloadingURL, pipingData, isCanceled;
	off_t readPointer, writePointer;
    NSDate *previousCheck;
	double previousProcessProgress;
	
}
@property (nonatomic, readonly) NSString *showTitleForFiles;


@end

@implementation MTDownload


@synthesize encodeFilePath   = _encodeFilePath,
downloadFilePath = _downloadFilePath,
bufferFilePath   = _bufferFilePath;

__DDLOGHERE__

-(id)init
{
    self = [super init];
    if (self) {
        encoderTask = nil;
 		decryptFilePath = nil;
        commercialFilePath = nil;
		captionFilePath = nil;
		_addToiTunesWhenEncoded = NO;
        _simultaneousEncode = YES;
		encoderTask = nil;
		decrypterTask = nil;
		captionTask = nil;
		apmTask = nil;
		writingData = NO;
		downloadingURL = NO;
		pipingData = NO;
        pipe1 = nil;
        pipe2 = nil;
		_genTextMetaData = nil;
		_genXMLMetaData = nil;
		_includeAPMMetaData = nil;
		_exportSubtitles = nil;
		
        [self addObserver:self forKeyPath:@"downloadStatus" options:NSKeyValueObservingOptionNew context:nil];
        previousCheck = [[NSDate date] retain];
		//Make sure /tmp/ctivo/ directory exists
		NSString *ctivoTmp = @"/tmp/ctivo/";
		if (![[NSFileManager defaultManager] fileExistsAtPath:ctivoTmp]) {
			[[NSFileManager defaultManager] createDirectoryAtPath:ctivoTmp withIntermediateDirectories:YES attributes:nil error:nil];
		}
    }
    return self;
}

-(void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath compare:@"downloadStatus"] == NSOrderedSame) {
		DDLogVerbose(@"Changing DL status of %@ to %@", object, [(MTDownload *)object downloadStatus]);
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationDownloadStatusChanged object:nil];
    }
}


-(void) saveLogFile: (NSFileHandle *) logHandle {
	if (ddLogLevel >= LOG_LEVEL_DETAIL) {
		unsigned long long logFileSize = [logHandle seekToEndOfFile];
		NSInteger backup = 2000;  //how much to log
		if (logFileSize < backup) backup = (NSInteger)logFileSize;
		[logHandle seekToFileOffset:(logFileSize-backup)];
		NSData *tailOfFile = [logHandle readDataOfLength:backup];
		if (tailOfFile.length > 0) {
			NSString * logString = [[[NSString alloc] initWithData:tailOfFile encoding:NSUTF8StringEncoding] autorelease];
			DDLogDetail(@"logFile: %@",  logString);
		}
	}
}

-(void) saveCurrentLogFile {
	switch (_downloadStatus.intValue) {
		case  kMTStatusDownloading : {
			if (self.simultaneousEncode) {
				DDLogMajor(@"%@ simul-downloaded %f of %f bytes; %ld%%",self,dataDownloaded, _show.fileSize, lround(_processProgress*100));
				NSFileHandle * logHandle = [NSFileHandle fileHandleForReadingAtPath:encodeLogFilePath] ;
				[self saveLogFile:logHandle];
			} else {
				DDLogMajor(@"%@ downloaded %f of %f bytes; %ld%%",self,dataDownloaded, _show.fileSize, lround(_processProgress*100));
				[self saveLogFile:encodeLogFileReadHandle];
				NSFileHandle * logHandle = [NSFileHandle fileHandleForReadingAtPath:encodeErrorFilePath] ;
				[self saveLogFile:logHandle];
				
			}
			break;
		}
		case  kMTStatusDecrypting : {
			[self saveLogFile: decryptLogFileReadHandle];
			break;
		}
		case  kMTStatusCommercialing :{
			[self saveLogFile: commercialLogFileReadHandle];
			break;
		}
		case  kMTStatusCaptioning :{
			[self saveLogFile: captionLogFileReadHandle];
			break;
		}
		case  kMTStatusEncoding :{
			[self saveLogFile: encodeLogFileReadHandle];
			break;
		}
		default: {
			DDLogMajor (@"%@ Strange failure;",self );
		}
			
			
	}
}


-(void)rescheduleShowWithDecrementRetries:(NSNumber *)decrementRetries
{
	DDLogMajor(@"Stalled at %@, %@ download of %@ with progress at %lf with previous check at %@",self.showStatus,(_numRetriesRemaining > 0) ? @"restarting":@"canceled",  _show.showTitle, _processProgress, previousCheck );
	[self saveCurrentLogFile];
	[self cancel];
	if (_numRetriesRemaining <= 0 || _numStartupRetriesRemaining <=0) {
		[self setValue:[NSNumber numberWithInt:kMTStatusFailed] forKeyPath:@"downloadStatus"];
		_processProgress = 1.0;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		
		[tiVoManager  notifyWithTitle: @"TiVo show failed; cancelled."
							 subTitle:self.show.showTitle forNotification:kMTGrowlEndDownload];
		
	} else {
		if ([decrementRetries boolValue]) {
			_numRetriesRemaining--;
			[tiVoManager  notifyWithTitle:@"TiVo show failed; retrying..." subTitle:self.show.showTitle forNotification:kMTGrowlEndDownload];
			DDLogDetail(@"Decrementing retries to %d",_numRetriesRemaining);
		} else {
            _numStartupRetriesRemaining--;
			DDLogDetail(@"Decrementing startup retries to %d",_numStartupRetriesRemaining);
		}
		[self setValue:[NSNumber numberWithInt:kMTStatusNew] forKeyPath:@"downloadStatus"];
	}
    NSNotification *notification = [NSNotification notificationWithName:kMTNotificationDownloadQueueUpdated object:self.show.tiVo];
    [[NSNotificationCenter defaultCenter] performSelector:@selector(postNotification:) withObject:notification afterDelay:4.0];
	
}

#pragma mark - Queue encoding/decoding methods for persistent queue, copy/paste, and drag/drop

- (void) encodeWithCoder:(NSCoder *)encoder {
	//necessary for cut/paste drag/drop. Not used for persistent queue, as we like having english readable pref lists
	//keep parallel with queueRecord
	DDLogVerbose(@"encoding %@",self);
	[self.show encodeWithCoder:encoder];
	[encoder encodeObject:[NSNumber numberWithBool:_addToiTunesWhenEncoded] forKey: kMTSubscribediTunes];
	[encoder encodeObject:[NSNumber numberWithBool:_simultaneousEncode] forKey: kMTSubscribedSimulEncode];
	[encoder encodeObject:[NSNumber numberWithBool:_skipCommercials] forKey: kMTSubscribedSkipCommercials];
	[encoder encodeObject:_encodeFormat.name forKey:kMTQueueFormat];
	[encoder encodeObject:_downloadStatus forKey: kMTQueueStatus];
	[encoder encodeObject: _downloadDirectory forKey: kMTQueueDirectory];
	[encoder encodeObject: _downloadFilePath forKey: kMTQueueDownloadFile] ;
	[encoder encodeObject: _bufferFilePath forKey: kMTQueueBufferFile] ;
	[encoder encodeObject: _encodeFilePath forKey: kMTQueueFinalFile] ;
	[encoder encodeObject: _genTextMetaData forKey: kMTQueueGenTextMetaData];
	[encoder encodeObject: _genXMLMetaData forKey:	kMTQueueGenXMLMetaData];
	[encoder encodeObject: _includeAPMMetaData forKey:	kMTQueueIncludeAPMMetaData];
	[encoder encodeObject: _exportSubtitles forKey:	kMTQueueExportSubtitles];
}

- (NSDictionary *) queueRecord {
	//used for persistent queue, as we like having english-readable pref lists
	//keep parallel with encodeWithCoder
	//need to watch out for a nil object ending the dictionary too soon.
	DDLogDetail(@"queueRecord for %@",self);

	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObjectsAndKeys:
								   [NSNumber numberWithInteger: _show.showID], kMTQueueID,
								   [NSNumber numberWithBool:_addToiTunesWhenEncoded], kMTSubscribediTunes,
								   [NSNumber numberWithBool:_simultaneousEncode], kMTSubscribedSimulEncode,
								   [NSNumber numberWithBool:_skipCommercials], kMTSubscribedSkipCommercials,
								   _show.showTitle, kMTQueueTitle,
								   self.show.tiVoName, kMTQueueTivo,
								   nil];
	if (_encodeFormat.name) [result setValue:_encodeFormat.name forKey:kMTQueueFormat];
	if (_downloadStatus) [result setValue:_downloadStatus forKey:kMTQueueStatus];
	if (_downloadDirectory) [result setValue:_downloadDirectory forKey:kMTQueueDirectory];
	if (_downloadFilePath) [result setValue:_downloadFilePath forKey:kMTQueueDownloadFile];
	if (_bufferFilePath) [result setValue:_bufferFilePath forKey: kMTQueueBufferFile];
	if (_encodeFilePath) [result setValue:_encodeFilePath forKey: kMTQueueFinalFile];
	if (_genTextMetaData) [result setValue:_genTextMetaData forKey: kMTQueueGenTextMetaData];
	if (_genXMLMetaData) [result setValue:_genXMLMetaData forKey: kMTQueueGenXMLMetaData];
	if (_includeAPMMetaData) [result setValue:_includeAPMMetaData forKey: kMTQueueIncludeAPMMetaData];
	if (_exportSubtitles) [result setValue:_exportSubtitles forKey: kMTQueueExportSubtitles];
	
	DDLogVerbose(@"queueRecord for %@ is %@",self,result);
	return [NSDictionary dictionaryWithDictionary: result];
}

-(BOOL) isSameAs:(NSDictionary *) queueEntry {
	NSInteger queueID = [queueEntry[kMTQueueID] integerValue];
	BOOL result = (queueID == _show.showID) && ([self.show.tiVoName compare:queueEntry[kMTQueueTivo]] == NSOrderedSame);
	if (result && [self.show.showTitle compare:queueEntry[kMTQueueTitle]] != NSOrderedSame) {
		NSLog(@"Very odd, but reloading anyways: same ID: %ld same TiVo:%@ but different titles: <<%@>> vs <<%@>>",queueID, queueEntry[kMTQueueTivo], self.show.showTitle, queueEntry[kMTQueueTitle] );
	}
	return result;
	
}

-(void) restoreDownloadData:queueEntry {
	self.show = [[[MTTiVoShow alloc] init] autorelease];
	self.show.showID   = [(NSNumber *)queueEntry[kMTQueueID] intValue];
	self.show.showTitle= queueEntry[kMTQueueTitle];
	self.show.tempTiVoName = queueEntry[kMTQueueTivo] ;

	[self prepareForDownload:NO];
	_addToiTunesWhenEncoded = [queueEntry[kMTSubscribediTunes ]  boolValue];
	_skipCommercials = [queueEntry[kMTSubscribedSkipCommercials ]  boolValue];
	_downloadStatus = queueEntry[kMTQueueStatus];
	if (_downloadStatus.integerValue == kMTStatusDoneOld) _downloadStatus = @kMTStatusDone; //temporary patch for old queues
	if (self.isInProgress) _downloadStatus = @kMTStatusNew;		//until we can launch an in-progress item
	
	_simultaneousEncode = [queueEntry[kMTSimultaneousEncode] boolValue];
	self.encodeFormat = [tiVoManager findFormat: queueEntry[kMTQueueFormat]]; //bug here: will not be able to restore a no-longer existent format, so will substitue with first one available, which is wrong for completed/failed entries
	self.downloadDirectory = queueEntry[kMTQueueDirectory];
	_encodeFilePath = [queueEntry[kMTQueueFinalFile] retain];
	_downloadFilePath = [queueEntry[kMTQueueDownloadFile] retain];
	_bufferFilePath = [queueEntry[kMTQueueBufferFile] retain];
	self.show.protectedShow = self.isDone ? @NO : @YES;
	_genTextMetaData = [queueEntry[kMTQueueGenTextMetaData] retain]; if (!_genTextMetaData) _genTextMetaData= @(NO);
	_genXMLMetaData = [queueEntry[kMTQueueGenXMLMetaData] retain]; if (!_genXMLMetaData) _genXMLMetaData= @(NO);
	_includeAPMMetaData = [queueEntry[kMTQueueIncludeAPMMetaData] retain]; if (!_includeAPMMetaData) _includeAPMMetaData= @(NO);
	_exportSubtitles = [queueEntry[kMTQueueExportSubtitles] retain]; if (!_exportSubtitles) _exportSubtitles= @(NO);
	DDLogDetail(@"restored %@ with %@; inProgress",self, queueEntry);
}

- (id)initWithCoder:(NSCoder *)decoder {
	//keep parallel with updateFromDecodedShow
	if ((self = [self init])) {
		//NSString *title = [decoder decodeObjectForKey:kTitleKey];
		//float rating = [decoder decodeFloatForKey:kRatingKey];
		self.show = [[[MTTiVoShow alloc] initWithCoder:decoder ] autorelease];
		self.downloadDirectory = [decoder decodeObjectForKey: kMTQueueDirectory];
		_addToiTunesWhenEncoded= [[decoder decodeObjectForKey: kMTSubscribediTunes] boolValue];
		_simultaneousEncode	 =   [[decoder decodeObjectForKey: kMTSubscribedSimulEncode] boolValue];
		_skipCommercials   =     [[decoder decodeObjectForKey: kMTSubscribedSkipCommercials] boolValue];
		NSString * encodeName	 = [decoder decodeObjectForKey:kMTQueueFormat];
		_encodeFormat =	[[tiVoManager findFormat: encodeName] retain]; //minor bug here: will not be able to restore a no-longer existent format, so will substitue with first one available, which is then wrong for completed/failed entries
		_downloadStatus		 = [[decoder decodeObjectForKey: kMTQueueStatus] retain];
		_bufferFilePath = [[decoder decodeObjectForKey:kMTQueueBufferFile] retain];
		_downloadFilePath = [[decoder decodeObjectForKey:kMTQueueDownloadFile] retain];
		_encodeFilePath = [[decoder decodeObjectForKey:kMTQueueFinalFile] retain];
		_genTextMetaData = [[decoder decodeObjectForKey:kMTQueueGenTextMetaData] retain]; if (!_genTextMetaData) _genTextMetaData= @(NO);
		_genXMLMetaData = [[decoder decodeObjectForKey:kMTQueueGenXMLMetaData] retain]; if (!_genXMLMetaData) _genXMLMetaData= @(NO);
		_includeAPMMetaData = [[decoder decodeObjectForKey:kMTQueueIncludeAPMMetaData] retain]; if (!_includeAPMMetaData) _includeAPMMetaData= @(NO);
		_exportSubtitles = [[decoder decodeObjectForKey:kMTQueueExportSubtitles] retain]; if (!_exportSubtitles) _exportSubtitles= @(NO);
	}
	DDLogDetail(@"initWithCoder for %@",self);
	return self;
}


-(BOOL) isEqual:(id)object {
	MTDownload * dl = (MTDownload *) object;
	return ([self.show isEqual:dl.show] &&
			[self.encodeFormat isEqual: dl.encodeFormat] &&
			(self.downloadFilePath == dl.downloadFilePath || [self.downloadFilePath isEqual:dl.downloadFilePath]) &&
			(self.downloadDirectory == dl.downloadDirectory || [self.downloadDirectory isEqual:dl.downloadDirectory]));

}

- (id)pasteboardPropertyListForType:(NSString *)type {
	NSLog(@"QQQ:pboard Type: %@",type);
	if ([type compare:kMTDownloadPasteBoardType] ==NSOrderedSame) {
		return  [NSKeyedArchiver archivedDataWithRootObject:self];
	} else if ([type isEqualToString:(NSString *)kUTTypeFileURL] && self.encodeFilePath) {
		NSURL *URL = [NSURL fileURLWithPath:self.encodeFilePath isDirectory:NO];
		NSLog(@"file: %@ ==> pBoard URL: %@",self.encodeFilePath, URL);
		id temp =  [URL pasteboardPropertyListForType:(id)kUTTypeFileURL];
		return temp;
	} else {
		return nil;
	}
}
-(NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard {
	NSArray* result = [NSArray  arrayWithObjects: kMTDownloadPasteBoardType , kUTTypeFileURL, nil];  //NOT working yet
	NSLog(@"QQQ:writeable Type: %@",result);
	return result;
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard {
	return 0;
}

+ (NSArray *)readableTypesForPasteboard:(NSPasteboard *)pasteboard {
	return @[kMTDownloadPasteBoardType];
	
}
+ (NSPasteboardReadingOptions)readingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard {
	if ([type compare:kMTDownloadPasteBoardType] ==NSOrderedSame)
		return NSPasteboardReadingAsKeyedArchive;
	return 0;
}



#pragma mark - Set up for queuing / reset
-(void)prepareForDownload: (BOOL) notifyTiVo {
	//set up initial parameters for download before submittal; can also be used to resubmit while still in DL queue
	self.show.isQueued = YES;
	if (self.isInProgress) {
		[self cancel];
	}
	self.numRetriesRemaining = [[NSUserDefaults standardUserDefaults] integerForKey:kMTNumDownloadRetries];
	self.numStartupRetriesRemaining = kMTMaxDownloadStartupRetries;
	if (!self.downloadDirectory) {
		self.downloadDirectory = tiVoManager.downloadDirectory;
	}
	[self setValue:[NSNumber numberWithInt:kMTStatusNew] forKeyPath:@"downloadStatus"];
	if (notifyTiVo) {
		NSNotification *notification = [NSNotification notificationWithName:kMTNotificationDownloadQueueUpdated object:self.show.tiVo];
		[[NSNotificationCenter defaultCenter] performSelector:@selector(postNotification:) withObject:notification afterDelay:4.0];
	}
}


#pragma mark - Download/conversion file Methods

//Method called at the beginning of the download to configure all required files and file handles

-(void)deallocDownloadHandling
{
    if (_downloadFilePath) {
        [_downloadFilePath release];
        _downloadFilePath = nil;
    }
    if (downloadFileHandle && downloadFileHandle != [pipe1 fileHandleForWriting]) {
        [downloadFileHandle release];
        downloadFileHandle = nil;
    }
    if (decrypterTask) {
		if ([decrypterTask isRunning]) {
			[decrypterTask terminate];
		}
        [decrypterTask release];
        decrypterTask = nil;
    }
    if (decryptFilePath) {
        [decryptFilePath release];
        decryptFilePath = nil;
    }
    if (decryptLogFilePath) {
        [decryptLogFilePath release];
        decryptLogFilePath = nil;
    }
    if (decryptLogFileHandle) {
        [decryptLogFileHandle closeFile];
        [decryptLogFileHandle release];
        decryptLogFileHandle = nil;
    }
    if (decryptLogFileReadHandle) {
        [decryptLogFileReadHandle closeFile];
        [decryptLogFileReadHandle release];
        decryptLogFileReadHandle = nil;
    }
    if (commercialFilePath) {
        [commercialFilePath release];
        commercialFilePath = nil;
    }
    if (commercialFileHandle) {
        [commercialFileHandle release];
        commercialFileHandle = nil;
    }
    if (commercialLogFilePath) {
        [commercialLogFilePath release];
        commercialLogFilePath = nil;
    }
    if (commercialLogFileHandle) {
        [commercialLogFileHandle closeFile];
        [commercialLogFileHandle release];
        commercialLogFileHandle = nil;
    }
    if (commercialLogFileReadHandle) {
        [commercialLogFileReadHandle closeFile];
        [commercialLogFileReadHandle release];
        commercialLogFileReadHandle = nil;
    }
    if (captionFilePath) {
        [captionFilePath release];
        captionFilePath = nil;
    }
    if (captionFileHandle) {
        [captionFileHandle release];
        captionFileHandle = nil;
    }
    if (captionLogFilePath) {
        [captionLogFilePath release];
        captionLogFilePath = nil;
    }
    if (captionLogFileHandle) {
        [captionLogFileHandle closeFile];
        [captionLogFileHandle release];
        captionLogFileHandle = nil;
    }
    if (captionLogFileReadHandle) {
        [captionLogFileReadHandle closeFile];
        [captionLogFileReadHandle release];
        captionLogFileReadHandle = nil;
    }
    if (encoderTask) {
		if ([encoderTask isRunning]) {
			[encoderTask terminate];
		}
        [encoderTask release];
        encoderTask = nil;
    }
    if (_encodeFilePath) {
        [_encodeFilePath release];
        _encodeFilePath = nil;
    }
    if (encodeFileHandle) {
        [encodeFileHandle closeFile];
        [encodeFileHandle release];
        encodeFileHandle = nil;
    }
    if (encodeLogFilePath) {
        [encodeLogFilePath release];
        encodeLogFilePath = nil;
    }
    if (encodeLogFileHandle) {
        [encodeLogFileHandle closeFile];
        [encodeLogFileHandle release];
        encodeLogFileHandle = nil;
    }
    if (encodeErrorFilePath) {
        [encodeErrorFilePath release];
        encodeErrorFilePath = nil;
    }
    if (encodeErrorFileHandle) {
        [encodeErrorFileHandle closeFile];
        [encodeErrorFileHandle release];
        encodeErrorFileHandle = nil;
    }
    if (encodeLogFileReadHandle) {
        [encodeLogFileReadHandle closeFile];
        [encodeLogFileReadHandle release];
        encodeLogFileReadHandle = nil;
    }
    if (_bufferFilePath) {
        [_bufferFilePath release];
        _bufferFilePath = nil;
    }
    if (bufferFileReadHandle) {
        [bufferFileReadHandle closeFile];
        [bufferFileReadHandle release];
        bufferFileReadHandle = nil;
    }
    if (bufferFileWriteHandle) {
        [bufferFileWriteHandle closeFile];
        [bufferFileWriteHandle release];
        bufferFileWriteHandle = nil;
    }
    if (pipe1) {
        [pipe1 release];
		pipe1 = nil;
    }
    if (pipe2) {
        [pipe2 release];
		pipe2 = nil;
    }
}

-(void)cleanupFiles
{
	BOOL deleteFiles = ![[NSUserDefaults standardUserDefaults] boolForKey:kMTSaveTmpFiles];
    NSFileManager *fm = [NSFileManager defaultManager];
    DDLogDetail(@"%@ cleaningup files",self.show.showTitle);
	if (_downloadFilePath) {
        [downloadFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting DL %@",_downloadFilePath);
			[fm removeItemAtPath:_downloadFilePath error:nil];
		}
		[downloadFileHandle release]; downloadFileHandle = nil;
		[_downloadFilePath release]; _downloadFilePath = nil;
    }
    if (_bufferFilePath) {
        [bufferFileReadHandle closeFile];
        [bufferFileWriteHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting buffer %@",_bufferFilePath);
			[fm removeItemAtPath:_bufferFilePath error:nil];
		}
		[bufferFileReadHandle release]; bufferFileReadHandle = nil;
		[bufferFileWriteHandle release]; bufferFileWriteHandle = nil;
		[_bufferFilePath release]; _bufferFilePath = nil;
    }
    if (commercialLogFileHandle) {
        [commercialLogFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting commLog %@",commercialLogFilePath);
			[fm removeItemAtPath:commercialLogFilePath error:nil];
		}
		[commercialLogFileHandle release]; commercialLogFileHandle = nil;
		[commercialLogFilePath release]; commercialLogFilePath = nil;
    }
	if (commercialFilePath) {
        [commercialFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting comm %@",commercialFilePath);
			[fm removeItemAtPath:commercialFilePath error:nil];
		}
		[commercialFileHandle release]; commercialFileHandle = nil;
		[commercialFilePath release]; commercialFilePath = nil;
    }
    if (captionLogFileHandle) {
        [captionLogFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting captionLog %@",captionLogFilePath);
			[fm removeItemAtPath:captionLogFilePath error:nil];
		}
		[captionLogFileHandle release]; captionLogFileHandle = nil;
		[captionLogFilePath release]; captionLogFilePath = nil;
    }
	if (captionFilePath) {
        [captionFileHandle closeFile];
		[captionFileHandle release]; captionFileHandle = nil;
		[captionFilePath release]; captionFilePath = nil;
    }
    if (encodeLogFileHandle) {
        [encodeLogFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting encodeLog %@",encodeLogFilePath);
			[fm removeItemAtPath:encodeLogFilePath error:nil];
		}
		[encodeLogFileHandle release]; encodeLogFileHandle = nil;
		[encodeLogFilePath release]; encodeLogFilePath = nil;
    }
    if (encodeErrorFileHandle) {
        [encodeErrorFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting encodeError %@",encodeErrorFilePath);
			[fm removeItemAtPath:encodeErrorFilePath error:nil];
		}
		[encodeErrorFileHandle release]; encodeErrorFileHandle = nil;
		[encodeErrorFilePath release]; encodeErrorFilePath = nil;
    }
    if (decryptLogFileHandle) {
        [decryptLogFileHandle closeFile];
		if (deleteFiles) {
			DDLogVerbose(@"deleting decryptLog %@",decryptLogFilePath);
			[fm removeItemAtPath:decryptLogFilePath error:nil];
		}
		[decryptLogFileHandle release]; decryptLogFileHandle = nil;
		[decryptLogFilePath release]; decryptLogFilePath = nil;
    }
    if (decryptFilePath) {
		if (deleteFiles) {
			DDLogVerbose(@"deleting decrypt %@",decryptFilePath);
			[fm removeItemAtPath:decryptFilePath error:nil];
		}
		[decryptFilePath release]; decryptFilePath = nil;
    }
	//Clean up files in /tmp/ctivo/
	if (deleteFiles) {
		NSArray *tmpFiles = [fm contentsOfDirectoryAtPath:@"/tmp/ctivo" error:nil];
		[fm changeCurrentDirectoryPath:@"/tmp/ctivo"];
		NSString * baseName = [self showTitleForFiles];
		for(NSString *file in tmpFiles){
			NSRange tmpRange = [file rangeOfString:baseName];
			if(tmpRange.location != NSNotFound) {
				DDLogDetail(@"Deleting tmp file %@", file);
				[fm removeItemAtPath:file error:nil];
			}
		}
	}
}

-(NSString *) directoryForShowInDirectory:(NSString*) tryDirectory  {
	//Check that download directory (including show directory) exists.  If create it.  If unsuccessful return nil
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kMTMakeSubDirs] && ![self.show isMovie]){
		tryDirectory = [tryDirectory stringByAppendingPathComponent:self.show.seriesTitle];
		DDLogVerbose(@"Opening Series-specific folder %@",tryDirectory);
	}
	if (![[NSFileManager defaultManager] fileExistsAtPath: tryDirectory]) { // try to create it
		DDLogDetail(@"Creating folder %@",tryDirectory);
		if (![[NSFileManager defaultManager] createDirectoryAtPath:tryDirectory withIntermediateDirectories:YES attributes:nil error:nil]) {
			DDLogDetail(@"Couldn't create folder %@",tryDirectory);
			return nil;
		}
	}
	return tryDirectory;
}

/*
 [title] = The Big Bang Theory – The Loobenfeld Decay
 [mainTitle] = The Big Bang Theory
 [episodeTitle] = The Loobenfeld Decay
 [channelNum] = 702
 [channel] = KCBSDT
 [min] = 00
 [hour] = 20
 [wday] = Mon
 [mday] = 24
 [month] = Mar
 [monthNum] = 03
 [year] = 2008
 [originalAirDate] = 2007-11-20
 [EpisodeNumber] = 302
 [tivoName]
 [/]
 
 
 By request some more advanced keyword processing was introduced to allow for conditional text.
 
 You can define multiple space-separated fields within square brackets.
 Fields surrounded by quotes are treated as literal text.
 A single field with no quotes should be supplied which represents a conditional keyword
 If that keyword is available for the show in question then the keyword value along with any literal text surrounding it will be included in file name.
 If the keyword evaluates to null then the entire advanced keyword becomes null.
 For example:
 [mainTitle]["_Ep#" EpisodeNumber]_[wday]_[month]_[mday]
 The advanced keyword is highlighted in bold and signifies only include “_Ep#xxx” if EpisodeNumber exists for the show in question. “_Ep#” is literal string to which the evaluated contents of EpisodeNumber keyword are appended. If EpisodeNumber does not exist then the whole advanced keyword evaluates to empty string.
 
 
 
 -(NSString *) swapKeywordsInString: (NSString *) str {
 NSDictionary * keywords = @{
 @"[showTitle]": @"%$1$@",
 @"[series ]" : @"%$1$@"
 showTitle),				// %$1$@
 seriesTitle),			// %$2$@
 episodeTitle),			// %$3$@
 episodeNumber),			// %$4$@
 showDate),				// %$5$@
 showMediumDateString),	// %$6$@
 originalAirDate),		// %$7$@
 tiVoName),				// %$8$@
 idString),				// %$9$@
 channelString),			// %$10$@
 stationCallsign),		// %$11$@
 encodeFormat.name)		// %$12$@
 };
 for (NSString * key in [keywords allKeys]) {
 str = [str stringByReplacingOccurrencesOfString: key
 withString: keywords[key]
 options: NSCaseInsensitiveSearch
 range: NSMakeRange(0, [str length])];
 
 }
 return str;
 }
 */
#define Null(x) x ?  x : nullString

-(NSString *)showTitleForFiles
{
	NSString * baseTitle = _show.showTitle;
	NSString * filenamePattern = [[NSUserDefaults standardUserDefaults] objectForKey:kMTFileNameFormat];
	if (filenamePattern.length > 0) {
		NSString * nullString = [[NSUserDefaults standardUserDefaults] objectForKey:kMTFileNameFormatNull];
		if (!nullString) nullString = @"";
		baseTitle = [NSString stringWithFormat:filenamePattern,
					 Null(_show.showTitle),				// %$1$@  showTitle			Arrow: The Odyssey  or MovieTitle
					 Null(_show.seriesTitle),			// %$2$@  seriesTitle		Arrow or MovieTitle
					 Null(_show.episodeTitle),			// %$3$@  episodeTitle		The Odyssey or empty
					 Null(_show.episodeNumber),			// %$4$@  episodeNumber		S04 E05  or 53
					 Null(_show.showDate),				// %$5$@  showDate			Feb 10, 2013 8-00PM
					 Null(_show.showMediumDateString),	// %$6$@  showMedDate		2-10-13
					 Null(_show.originalAirDate),		// %$7$@  originalAirDate
					 Null(_show.tiVoName),				// %$8$@  tiVoName
					 Null(_show.idString),				// %$9$@  tiVoID
					 Null(_show.channelString),			// %$10$@ channelString
					 Null(_show.stationCallsign),			// %$11$@ stationCallsign
					 Null(self.encodeFormat.name)			// %$11$@ stationCallsign
					 ];
		//NEED Dates without times also Series ID
		if (baseTitle.length == 0) baseTitle = _show.showTitle;
		if (baseTitle.length > 245) baseTitle = [baseTitle substringToIndex:245];
	}
	NSString * safeTitle = [baseTitle stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
	safeTitle = [safeTitle stringByReplacingOccurrencesOfString:@":" withString:@"-"];
	if (LOG_VERBOSE  && [safeTitle compare: _show.showTitle ]  != NSOrderedSame) {
		DDLogVerbose(@"changed filename %@ to %@",_show.showTitle, safeTitle);
	}
	return safeTitle;
}
#undef Null

-(void)configureFiles
{
	DDLogDetail(@"configuring files for %@",self);
	//Release all previous attached pointers
    [self deallocDownloadHandling];
	NSString *downloadDir = [self directoryForShowInDirectory:[self downloadDirectory]];
	
	//go to current directory if one at show scheduling time failed
	if (!downloadDir) {
		downloadDir = [self directoryForShowInDirectory:[tiVoManager downloadDirectory]];
	}
    
	//finally, go to default if not successful
	if (!downloadDir) {
		downloadDir = [self directoryForShowInDirectory:[tiVoManager defaultDownloadDirectory]];
	}
	NSString * baseFileName = self.showTitleForFiles;
    _encodeFilePath = [[NSString stringWithFormat:@"%@/%@%@",downloadDir,baseFileName,_encodeFormat.filenameExtension] retain];
    DDLogVerbose(@"setting encodepath: %@", _encodeFilePath);
	NSFileManager *fm = [NSFileManager defaultManager];
    if (_simultaneousEncode) {
        //Things require uniquely for simultaneous download
        pipe1 = [[NSPipe pipe] retain];
        pipe2 = [[NSPipe pipe] retain];
		downloadFileHandle = [pipe1 fileHandleForWriting];
		DDLogVerbose(@"downloadFileHandle %@ for %@",downloadFileHandle,self);
        _bufferFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/buffer%@.bin",baseFileName] retain];
        [fm createFileAtPath:_bufferFilePath contents:[NSData data] attributes:nil];
        bufferFileReadHandle = [[NSFileHandle fileHandleForReadingAtPath:_bufferFilePath] retain];
        bufferFileWriteHandle = [[NSFileHandle fileHandleForWritingAtPath:_bufferFilePath] retain];
    } else {
        //Things require uniquely for sequential download
        _downloadFilePath = [[NSString stringWithFormat:@"%@/%@.tivo",downloadDir ,baseFileName] retain];
        [fm createFileAtPath:_downloadFilePath contents:[NSData data] attributes:nil];
        downloadFileHandle = [[NSFileHandle fileHandleForWritingAtPath:_downloadFilePath] retain];
		decryptFilePath = [[NSString stringWithFormat:@"%@/%@.tivo.mpg",downloadDir ,baseFileName] retain];
        decryptLogFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/decrypting%@.txt",baseFileName] retain];
        [fm createFileAtPath:decryptLogFilePath contents:[NSData data] attributes:nil];
        decryptLogFileHandle = [[NSFileHandle fileHandleForWritingAtPath:decryptLogFilePath] retain];
        decryptLogFileReadHandle = [[NSFileHandle fileHandleForReadingAtPath:decryptLogFilePath] retain];
 		commercialFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/%@.tivo.edl" ,baseFileName] retain];
        commercialLogFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/commercial%@.txt",baseFileName] retain];
        [fm createFileAtPath:commercialLogFilePath contents:[NSData data] attributes:nil];
        commercialLogFileHandle = [[NSFileHandle fileHandleForWritingAtPath:commercialLogFilePath] retain];
        commercialLogFileReadHandle = [[NSFileHandle fileHandleForReadingAtPath:commercialLogFilePath] retain];
        captionFilePath = [[NSString stringWithFormat:@"%@/%@.srt",downloadDir ,baseFileName] retain];
        captionLogFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/caption%@.txt",baseFileName] retain];
        [fm createFileAtPath:captionLogFilePath contents:[NSData data] attributes:nil];
        captionLogFileHandle = [[NSFileHandle fileHandleForWritingAtPath:captionLogFilePath] retain];
        captionLogFileReadHandle = [[NSFileHandle fileHandleForReadingAtPath:captionLogFilePath] retain];
        
    }
    
    encodeLogFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/encoding%@.txt",baseFileName] retain];
    [fm createFileAtPath:encodeLogFilePath contents:[NSData data] attributes:nil];
    encodeLogFileHandle = [[NSFileHandle fileHandleForWritingAtPath:encodeLogFilePath] retain];
    encodeLogFileReadHandle = [[NSFileHandle fileHandleForReadingAtPath:encodeLogFilePath] retain];
	
	encodeErrorFilePath = [[NSString stringWithFormat:@"/tmp/ctivo/encodingError%@.txt",baseFileName] retain];
    [fm createFileAtPath:encodeErrorFilePath contents:[NSData data] attributes:nil];
    encodeErrorFileHandle = [[NSFileHandle fileHandleForWritingAtPath:encodeErrorFilePath] retain];
}

-(NSString *) encoderPath {
	NSString *encoderLaunchPath = [_encodeFormat pathForExecutable];
    if (!encoderLaunchPath) {
        DDLogDetail(@"Encoding of %@ failed for %@ format, encoder %@ not found",_show.showTitle,_encodeFormat.name,_encodeFormat.encoderUsed);
        [self setValue:[NSNumber numberWithInt:kMTStatusFailed] forKeyPath:@"downloadStatus"];
        _processProgress = 1.0;
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
        return nil;
    } else {
		return encoderLaunchPath;
	}
}

#pragma mark - Download decrypt and encode Methods


-(NSMutableArray *)getArguments:(NSString *)argString
{
	NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"([^\\s\"\']+)|\"(.*?)\"|'(.*?)'" options:NSRegularExpressionCaseInsensitive error:nil];
	NSArray *matches = [regex matchesInString:argString options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, argString.length)];
	NSMutableArray *arguments = [NSMutableArray array];
	for (NSTextCheckingResult *tr in matches) {
		int j;
		for (j=1; j<tr.numberOfRanges; j++) {
			if ([tr rangeAtIndex:j].location != NSNotFound) {
				break;
			}
		}
		[arguments addObject:[argString substringWithRange:[tr rangeAtIndex:j]]];
	}
	DDLogVerbose(@"arguments: %@", arguments);
	return arguments;
	
}


-(NSMutableArray *)encodingArgumentsWithInputFile:(NSString *)inputFilePath outputFile:(NSString *)outputFilePath
{
	NSMutableArray *arguments = [NSMutableArray array];
    if ([_encodeFormat.encoderVideoOptions compare: @"VLC"] == NSOrderedSame) {
		[arguments addObject:@"-"];
	} else {
		
		if (_encodeFormat.encoderVideoOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.encoderVideoOptions]];
		if (_encodeFormat.encoderAudioOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.encoderAudioOptions]];
		if (_encodeFormat.encoderOtherOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.encoderOtherOptions]];
		if ([_encodeFormat.comSkip boolValue] && _skipCommercials && _encodeFormat.edlFlag.length) {
			[arguments addObject:_encodeFormat.edlFlag];
			[arguments addObject:commercialFilePath];
		}
		if (_encodeFormat.outputFileFlag.length) {
			[arguments addObject:_encodeFormat.outputFileFlag];
			[arguments addObject:outputFilePath];
			if (_encodeFormat.inputFileFlag.length) {
				[arguments addObject:_encodeFormat.inputFileFlag];
			}
			[arguments addObject:inputFilePath];
		} else {
			if (_encodeFormat.inputFileFlag.length) {
				[arguments addObject:_encodeFormat.inputFileFlag];
			}
			[arguments addObject:inputFilePath];
			[arguments addObject:outputFilePath];
		}
	}DDLogVerbose(@"encoding arguments: %@", arguments);
	return arguments;
}


-(void)download
{
	DDLogDetail(@"Starting download for %@",self);
	isCanceled = NO;
    //Before starting make sure the encoder is OK.
	NSString *encoderLaunchPath = [self encoderPath];
	if (!encoderLaunchPath) {
		return;
	}
	DDLogVerbose(@"encoder is %@",encoderLaunchPath);
	
    [self setValue:[NSNumber numberWithInt:kMTStatusDownloading] forKeyPath:@"downloadStatus"];
	if (!_show.gotDetails) {
		//		[self.show getShowDetail];
		//		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationTiVoShowsUpdated object:nil];
	}
    if (_simultaneousEncode && !_encodeFormat.canSimulEncode) {  //last chance check
		DDLogMajor(@"Odd; simultaneousEncode is wrong");
		_simultaneousEncode = NO;
    }
    [self configureFiles];
    NSURLRequest *thisRequest = [NSURLRequest requestWithURL:self.show.downloadURL];
	//    activeURLConnection = [NSURLConnection connectionWithRequest:thisRequest delegate:self];
    activeURLConnection = [[[NSURLConnection alloc] initWithRequest:thisRequest delegate:self startImmediately:NO] autorelease];
	
	//Now set up for either simul or sequential download
	DDLogMajor(@"Starting %@ of %@", (_simultaneousEncode ? @"simul DL" : @"download"), _show.showTitle);
	[tiVoManager  notifyWithTitle: [NSString stringWithFormat: @"TiVo %@ starting download...",self.show.tiVoName]
						 subTitle:self.show.showTitle forNotification:kMTGrowlBeginDownload];
	if (!_simultaneousEncode ) {
        _isSimultaneousEncoding = NO;
    } else { //We'll build the full piped download chain here
		DDLogDetail(@"building pipeline");
		//Decrypting section of full pipeline
        decrypterTask  = [[NSTask alloc] init];
        NSString *tivodecoderLaunchPath = [[NSBundle mainBundle] pathForResource:@"tivodecode" ofType:@""];
		[decrypterTask setLaunchPath:tivodecoderLaunchPath];
		NSMutableArray *arguments = [NSMutableArray arrayWithObjects:
									 [NSString stringWithFormat:@"-m%@",_show.tiVo.mediaKey],
									 @"--",
									 @"-",
									 nil];
        DDLogVerbose(@"decrypterArgs: %@",arguments);
		[decrypterTask setArguments:arguments];
        [decrypterTask setStandardInput:pipe1];
        [decrypterTask setStandardOutput:pipe2];
		
		//		if (self.exportSubtitles) {
		//			captionTask = [[NSTask alloc] init];
		//			[captionTask setLaunchPath:[[NSBundle mainBundle] pathForResource:@"ccextractor" ofType:@""]];
		//			[captionTask setStandardInput:pipe2];
		//			[captionTask setStandardOutput:pipe3];
		//			[captionTask setStandardError:captionLogFileHandle];
		//			NSArray * captionArgs = [NSMutableArray array];
		//			DDLogVerbose(@"captionArgs: %@",captionArgs);
		//
		//			if (_encodeFormat.captionOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.captionOptions]];
		//			//if (_encodeFormat.ccextractionOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.ccextractionOptions]];
		//			DDLogVerbose(@"ccextraction args: %@",arguments);
		//			[captionTask setArguments:captionArgs];
		//
		//		}
		
		
		encoderTask = [[NSTask alloc] init];
		[encoderTask setLaunchPath:encoderLaunchPath];
		NSArray * encoderArgs = [self encodingArgumentsWithInputFile:@"-" outputFile:_encodeFilePath];
		DDLogVerbose(@"encoderArgs: %@",encoderArgs);
		[encoderTask setArguments:encoderArgs];
		//		if (self.exportSubtitles) {
		//			[encoderTask setStandardInput:pipe3];
		//		} else {
		[encoderTask setStandardInput:pipe2];
		//		}
		[encoderTask setStandardOutput:encodeLogFileHandle];
		[encoderTask setStandardError:encodeLogFileHandle];
        
		[decrypterTask launch];
		//		if (self.exportSubtitles) [captionTask launch];
		[encoderTask launch];
		
        _isSimultaneousEncoding = YES;
    }
	downloadingURL = YES;
    dataDownloaded = 0.0;
    _processProgress = 0.0;
	DDLogVerbose(@"launching URL for download %@", _show.downloadURL);
	previousProcessProgress = 0.0;
	[activeURLConnection start];
	[self performSelector:@selector(checkStillActive) withObject:nil afterDelay:kMTProgressCheckDelay];
}


-(void)decrypt
{
	DDLogMajor(@"Starting Decrypt of  %@", self.show.showTitle);
	decrypterTask = [[NSTask alloc] init];
	[decrypterTask setLaunchPath:[[NSBundle mainBundle] pathForResource:@"tivodecode" ofType:@""]];
	[decrypterTask setStandardOutput:decryptLogFileHandle];
	[decrypterTask setStandardError:decryptLogFileHandle];
    // tivodecode -m0636497662 -o Two\ and\ a\ Half\ Men.mpg -v Two\ and\ a\ Half\ Men.TiVo
    
	NSArray *arguments = [NSArray arrayWithObjects:
						  [NSString stringWithFormat:@"-m%@",self.show.tiVo.mediaKey],
						  [NSString stringWithFormat:@"-o%@",decryptFilePath],
						  @"-v",
						  _downloadFilePath,
						  nil];
    DDLogVerbose(@"decrypt args: %@",arguments);
	_processProgress = 0.0;
	previousProcessProgress = 0.0;
	[self performSelector:@selector(checkStillActive) withObject:nil afterDelay:kMTProgressCheckDelay];
 	[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
    [self setValue:[NSNumber numberWithInt:kMTStatusDecrypting] forKeyPath:@"downloadStatus"];
	[decrypterTask setArguments:arguments];
	[decrypterTask launch];
	[self performSelector:@selector(trackDecrypts) withObject:nil afterDelay:0.3];
	
}

-(void)trackDecrypts
{
	if (![decrypterTask isRunning]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkStillActive) object:nil];
        DDLogMajor(@"Finished Decrypt of  %@", self.show.showTitle);
		_processProgress = 1.0;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
        [self setValue:[NSNumber numberWithInt:kMTStatusDecrypted] forKeyPath:@"downloadStatus"];
		if (![[NSUserDefaults standardUserDefaults] boolForKey:kMTSaveTmpFiles]) {
			NSError *thisError = nil;
			[[NSFileManager defaultManager] removeItemAtPath:_downloadFilePath error:&thisError];
		}
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationDecryptDidFinish object:self.show.tiVo];
		return;
	}
	unsigned long long logFileSize = [decryptLogFileReadHandle seekToEndOfFile];
	if (logFileSize > 100) {
		[decryptLogFileReadHandle seekToFileOffset:(logFileSize-100)];
		NSData *tailOfFile = [decryptLogFileReadHandle readDataOfLength:100];
		NSString *data = [[[NSString alloc] initWithData:tailOfFile encoding:NSUTF8StringEncoding] autorelease];
		NSArray *lines = [data componentsSeparatedByString:@"\n"];
		data = [lines objectAtIndex:lines.count-2];
		lines = [data componentsSeparatedByString:@":"];
		double position = [[lines objectAtIndex:0] doubleValue];
		_processProgress = position/_show.fileSize;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		
	}
	[self performSelector:@selector(trackDecrypts) withObject:nil afterDelay:0.3];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
	
}

-(void)commercial
{
	DDLogMajor(@"Starting commskip of  %@", self.show.showTitle);
	commercialTask = [[NSTask alloc] init];
	[commercialTask setLaunchPath:[[NSBundle mainBundle] pathForResource:@"comskip" ofType:@""]];
	[commercialTask setStandardOutput:commercialLogFileHandle];
	[commercialTask setStandardError:commercialLogFileHandle];
	NSMutableArray *arguments = [NSMutableArray array];
    if (_encodeFormat.comSkipOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.comSkipOptions]];
    [arguments addObject:[NSString stringWithFormat: @"--output=%@",[commercialFilePath stringByDeletingLastPathComponent]]];
	[arguments addObject:decryptFilePath];
	DDLogVerbose(@"comskip args: %@",arguments);
	[commercialTask setArguments:arguments];
    _processProgress = 0.0;
	previousProcessProgress = 0.0;
	[commercialTask launch];
	[self setValue:[NSNumber numberWithInt:kMTStatusCommercialing] forKeyPath:@"downloadStatus"];
	[self performSelector:@selector(trackCommercial) withObject:nil afterDelay:3.0];
}

-(void)trackCommercial
{
	if (![commercialTask isRunning]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkStillActive) object:nil];
        DDLogMajor(@"Finished detecting commercials in %@",self.show.showTitle);
		
		NSString * newCommercialPath = [_downloadDirectory stringByAppendingPathComponent: [commercialFilePath lastPathComponent]] ;
		[[NSFileManager defaultManager] removeItemAtPath:newCommercialPath error:nil ]; //just in case already there.
		NSError * error = nil;
		[[NSFileManager defaultManager] moveItemAtPath:commercialFilePath toPath:newCommercialPath error:&error];
		if (error) {
			DDLogMajor(@"Error moving commercial EDL file %@ to %@: %@",commercialFilePath, newCommercialPath, error.localizedDescription);
		} else {
			[commercialFilePath release];
			commercialFilePath = [newCommercialPath retain];
		}
		_processProgress = 1.0;
		[commercialTask release];
		commercialTask = nil;
        [self setValue:[NSNumber numberWithInt:kMTStatusCommercialed] forKeyPath:@"downloadStatus"];
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationCommercialDidFinish object:self];
		return;
	}
	double newProgressValue = 0;
	unsigned long long logFileSize = [commercialLogFileReadHandle seekToEndOfFile];
	if (logFileSize > 100) {
		[commercialLogFileReadHandle seekToFileOffset:(logFileSize-100)];
		NSData *tailOfFile = [commercialLogFileReadHandle readDataOfLength:100];
		NSString *data = [[[NSString alloc] initWithData:tailOfFile encoding:NSUTF8StringEncoding] autorelease];
		
		NSRegularExpression *percents = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\%" options:NSRegularExpressionCaseInsensitive error:nil];
		NSArray *values = [percents matchesInString:data options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, data.length)];
		NSTextCheckingResult *lastItem = [values lastObject];
		NSRange valueRange = [lastItem rangeAtIndex:1];
		newProgressValue = [[data substringWithRange:valueRange] doubleValue]/100.0;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		if (newProgressValue > _processProgress) {
			_processProgress = newProgressValue;
		}
	}
	[self performSelector:@selector(trackCommercial) withObject:nil afterDelay:0.5];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
	
}

-(void)caption
{
	DDLogMajor(@"Starting captioning of  %@", self.show.showTitle);
	captionTask = [[NSTask alloc] init];
	[captionTask setLaunchPath:[[NSBundle mainBundle] pathForResource:@"ccextractor" ofType:@""]];
	[captionTask setStandardOutput:captionLogFileHandle];
	[captionTask setStandardError:captionLogFileHandle];
	NSMutableArray *arguments = [NSMutableArray array];
	if (_encodeFormat.captionOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.captionOptions]];
    //if (_encodeFormat.ccextractionOptions.length) [arguments addObjectsFromArray:[self getArguments:_encodeFormat.ccextractionOptions]];
    [arguments addObject:decryptFilePath];
	[arguments addObject:@"-o"];
	[arguments addObject:captionFilePath ];
	DDLogVerbose(@"ccextraction args: %@",arguments);
	[captionTask setArguments:arguments];
    _processProgress = 0.0;
	previousProcessProgress = 0.0;
	[captionTask launch];
	[self setValue:[NSNumber numberWithInt:kMTStatusCaptioning] forKeyPath:@"downloadStatus"];
	[self performSelector:@selector(trackCaption) withObject:nil afterDelay:1];
}

-(void)trackCaption
{
	DDLogVerbose(@"QQQ Tracking Caption");
	if (![captionTask isRunning]) {
		[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkStillActive) object:nil];
        DDLogMajor(@"Finished detecting captions in %@",self.show.showTitle);
		
		_processProgress = 1.0;
		[captionTask release];
		captionTask = nil;
        [self setValue:[NSNumber numberWithInt:kMTStatusCaptioned] forKeyPath:@"downloadStatus"];
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationCaptionDidFinish object:self];
		return;
	}
	double newProgressValue = 0;
	unsigned long long logFileSize = [captionLogFileReadHandle seekToEndOfFile];
	if (logFileSize > 100) {
		[captionLogFileReadHandle seekToFileOffset:(logFileSize-100)];
		NSData *tailOfFile = [captionLogFileReadHandle readDataOfLength:100];
		NSString *data = [[[NSString alloc] initWithData:tailOfFile encoding:NSUTF8StringEncoding] autorelease];
		
		NSRegularExpression *percents = [NSRegularExpression regularExpressionWithPattern:@"(d+)%" options:NSRegularExpressionCaseInsensitive error:nil];
		NSArray *values = [percents matchesInString:data options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, data.length)];
		NSTextCheckingResult *lastItem = [values lastObject];
		NSRange valueRange = [lastItem rangeAtIndex:1];
		newProgressValue = [[data substringWithRange:valueRange] doubleValue]/100.0;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		if (newProgressValue > _processProgress) {
			_processProgress = newProgressValue;
		}
	}
	[self performSelector:@selector(trackCaption) withObject:nil afterDelay:0.5];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
	
}

-(void)encode
{
	NSString *encoderLaunchPath = [self encoderPath];
	if (!encoderLaunchPath) {
		return;
	}
	
    encoderTask = [[NSTask alloc] init];
    DDLogMajor(@"Starting Encode of   %@", self.show.showTitle);
    [encoderTask setLaunchPath:encoderLaunchPath];
    if (!_encodeFormat.canSimulEncode) {  //If can't simul encode have to depend on log file for tracking
		DDLogVerbose(@"Using logfile tracking");
        NSMutableArray *arguments = [self encodingArgumentsWithInputFile:decryptFilePath outputFile:_encodeFilePath];
        [encoderTask setArguments:arguments];
        [encoderTask setStandardOutput:encodeLogFileHandle];
        [encoderTask setStandardError:encodeErrorFileHandle];
        _processProgress = 0.0;
        previousProcessProgress = 0.0;
        [self performSelector:@selector(checkStillActive) withObject:nil afterDelay:kMTProgressCheckDelay];
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
        [encoderTask launch];
        [self setValue:[NSNumber numberWithInt:kMTStatusEncoding] forKeyPath:@"downloadStatus"];
        [self performSelector:@selector(trackEncodes) withObject:nil afterDelay:0.5];
    } else { //if can simul encode we can ignore the log file and just track an input pipe - more accurate and more general (even though we're not simultaneously downloading/encoding this time.
        if(pipe1){
            [pipe1 release];
        }
 		DDLogVerbose(@"Using pipe tracking");
        pipe1 = [[NSPipe pipe] retain];
        bufferFileReadHandle = [[NSFileHandle fileHandleForReadingAtPath:decryptFilePath] retain];
        NSMutableArray *arguments = [self encodingArgumentsWithInputFile:@"-" outputFile:_encodeFilePath];
        [encoderTask setArguments:arguments];
        [encoderTask setStandardInput:pipe1];
        [encoderTask setStandardOutput:encodeLogFileHandle];
        [encoderTask setStandardError:encodeErrorFileHandle];
        if (downloadFileHandle) {
            [downloadFileHandle release];
        }
        downloadFileHandle = [pipe1 fileHandleForWriting];
        _processProgress = 0.0;
        previousProcessProgress = 0.0;
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
        [encoderTask launch];
        [self setValue:[NSNumber numberWithInt:kMTStatusEncoding] forKeyPath:@"downloadStatus"];
        [self performSelectorInBackground:@selector(writeData) withObject:nil];
        [self performSelector:@selector(trackDownloadEncode) withObject:nil afterDelay:3.0];
    }
}


-(void) writeTextMetaData:(NSString*) value forKey: (NSString *) key toFile: (NSFileHandle *) handle {
	if ( key && value) {
		
		[handle writeData:[[NSString stringWithFormat:@"%@: %@\n",key, value] dataUsingEncoding:NSUTF8StringEncoding]];
	}
}

-(void) writeMetaDataFiles {
	
	if (self.genXMLMetaData.boolValue || self.genTextMetaData.boolValue) {
		
		NSString * tivoMetaPath = [[self.encodeFilePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"xml"];
		DDLogMajor(@"Writing XML to    %@",tivoMetaPath);
		if (![self.show.detailXML writeToFile:tivoMetaPath atomically:NO]) {
			DDLogReport(@"Couldn't write XML to file %@", tivoMetaPath);
			
		} else if (self.genTextMetaData.boolValue) {
			
			NSString * textMetaPath = [self.encodeFilePath stringByAppendingPathExtension:@"txt"];
			[[NSFileManager defaultManager] createFileAtPath:textMetaPath contents:[NSData data] attributes:nil];
			NSFileHandle * textMetaHandle = [NSFileHandle fileHandleForWritingAtPath:textMetaPath];
			DDLogMajor(@"Writing pytivo metaData to    %@",textMetaPath);
			
			NSString * xltTemplate = [[NSBundle mainBundle] pathForResource:@"pytivo_txt" ofType:@"xslt"];
			
			NSTask * xsltProcess = [[NSTask alloc] init];
			[xsltProcess setLaunchPath: @"/usr/bin/xsltproc"];
			[xsltProcess setArguments: @[ xltTemplate, tivoMetaPath]] ;
			[xsltProcess setStandardOutput:textMetaHandle ];
			[xsltProcess launch];
			[xsltProcess waitUntilExit];  //should be under 1 millisecond
			[xsltProcess release]; xsltProcess = nil;
			
			[self writeTextMetaData:self.show.seriesId		 forKey:@"seriesID"			    toFile:textMetaHandle];
			[self writeTextMetaData:self.show.channelString   forKey:@"displayMajorNumber"	toFile:textMetaHandle];
			[self writeTextMetaData:self.show.stationCallsign forKey:@"callsign"				toFile:textMetaHandle];
			[textMetaHandle closeFile];
			
			if (!self.genXMLMetaData.boolValue) {
				if (![[NSUserDefaults standardUserDefaults] boolForKey:kMTSaveTmpFiles]) {
					[[NSFileManager defaultManager] removeItemAtPath:tivoMetaPath error:nil];
				}
			}
		}
	}
}
-(BOOL) addAtomicParsleyMetadataToDownloadFile {
	if (! (self.includeAPMMetaData.boolValue && self.encodeFormat.canAtomicParsley)) {
		return NO;
	}
	DDLogMajor(@"Adding APM metaData to    %@",self);
	apmTask = [[NSTask alloc] init];
	[apmTask setLaunchPath:[[NSBundle mainBundle] pathForResource:@"AtomicParsley" ofType: @""] ];
	NSMutableArray *apmArgs =[NSMutableArray array];
	[apmArgs addObject:_encodeFilePath];
	[apmArgs addObjectsFromArray:[self.show apmArguments]];

	DDLogVerbose(@"APM Arguments: %@", apmArgs);
	[apmTask setArguments:apmArgs];
	NSString * apmLogFilePath = @"/tmp/ctivo/QQQAPM.log";
	[[NSFileManager defaultManager] createFileAtPath:apmLogFilePath contents:[NSData data] attributes:nil];
	
	[apmTask setStandardOutput:[NSFileHandle fileHandleForWritingAtPath:apmLogFilePath ]];
	[apmTask launch];
	[self performSelector:@selector(trackAPMProcess) withObject:nil afterDelay:1.0];
	return YES;
}

-(void) trackAPMProcess {
	DDLogVerbose(@"QQQTracking APM");
	if (![apmTask isRunning]) {
 		DDLogMajor(@"Finished atomic Parsley in %@",self.show.showTitle);
		[apmTask release]; apmTask = nil;
		
		[self finishUpPostEncodeProcessing];
	} else {
		[self performSelector:@selector(trackAPMProcess) withObject:nil afterDelay:0.5];
	}
}


-(void) finishUpPostEncodeProcessing {
	if (_addToiTunesWhenEncoded) {
		DDLogMajor(@"Adding to iTunes %@", self.show.showTitle);
		MTiTunes *iTunes = [[[MTiTunes alloc] init] autorelease];
		[iTunes importIntoiTunes:self];
	}
	[self setValue:[NSNumber numberWithInt:kMTStatusDone] forKeyPath:@"downloadStatus"];
	[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
	[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationEncodeDidFinish object:self];
	[tiVoManager  notifyWithTitle:@"TiVo show transferred." subTitle:self.show.showTitle forNotification:kMTGrowlEndDownload];
	
	[self cleanupFiles];
}

-(void) postEncodeProcessing {
	//shared between DownloadEncode (simultaneous) and trackEncodes (non-simul)
	_processProgress = 1.0;
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkStillActive) object:nil];
	if (! [[NSFileManager defaultManager] fileExistsAtPath:self.encodeFilePath] ) {
		DDLogReport(@" %@ File %@ not found after encoding complete",self, self.encodeFilePath );
		[self rescheduleShowWithDecrementRetries:@YES];
		
	} else {
		[self writeMetaDataFiles];
		if ( ! [self addAtomicParsleyMetadataToDownloadFile] ) {
			[self finishUpPostEncodeProcessing];
		} else {
			//APM process owns call finishUp after (potentially long) processing
		}
	}
}

-(void)trackDownloadEncode
{
    if([encoderTask isRunning]) {
        [self performSelector:@selector(trackDownloadEncode) withObject:nil afterDelay:0.3];
    } else {
        DDLogMajor(@"Finished simul encode of %@", self.show.showTitle);
		[self postEncodeProcessing];
    }
}

-(void)trackEncodes
{
	if (![encoderTask isRunning]) {
		DDLogMajor(@"Finished Encode of   %@",self.show.showTitle);
        [encoderTask release];
		encoderTask = nil;
		[self postEncodeProcessing];
		return;
	}
	double newProgressValue = 0;
	unsigned long long logFileSize = [encodeLogFileReadHandle seekToEndOfFile];
	if (logFileSize > 100) {
		[encodeLogFileReadHandle seekToFileOffset:(logFileSize-100)];
		NSData *tailOfFile = [encodeLogFileReadHandle readDataOfLength:100];
		NSString *data = [[[NSString alloc] initWithData:tailOfFile encoding:NSUTF8StringEncoding] autorelease];
		NSRegularExpression *percents = [NSRegularExpression regularExpressionWithPattern:_encodeFormat.regExProgress options:NSRegularExpressionCaseInsensitive error:nil];
		//		if ([_encodeFormat.encoderUsed caseInsensitiveCompare:@"mencoder"] == NSOrderedSame) {
		//			NSRegularExpression *percents = [NSRegularExpression regularExpressionWithPattern:@"\\((.*?)\\%\\)" options:NSRegularExpressionCaseInsensitive error:nil];
		NSArray *values = [percents matchesInString:data options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, data.length)];
		NSTextCheckingResult *lastItem = [values lastObject];
		NSRange valueRange = [lastItem rangeAtIndex:1];
		newProgressValue = [[data substringWithRange:valueRange] doubleValue]/100.0;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		//		}
		//		if ([_encodeFormat.encoderUsed caseInsensitiveCompare:@"HandBrakeCLI"] == NSOrderedSame) {
		//			NSRegularExpression *percents = [NSRegularExpression regularExpressionWithPattern:@" ([\\d.]*?) \\% " options:NSRegularExpressionCaseInsensitive error:nil];
		//			NSArray *values = [percents matchesInString:data options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, data.length)];
		//			if (values.count) {
		//				NSTextCheckingResult *lastItem = [values lastObject];
		//				NSRange valueRange = [lastItem rangeAtIndex:1];
		//				newProgressValue = [[data substringWithRange:valueRange] doubleValue]/102.0;
		//				[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		//			}
		//		}
		//if (newProgressValue > _processProgress) {
		_processProgress = newProgressValue;
		//		}
	}
	[self performSelector:@selector(trackEncodes) withObject:nil afterDelay:0.5];
    [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
}


-(void)cancel
{
    DDLogMajor(@"Canceling of         %@", self.show.showTitle);
    NSFileManager *fm = [NSFileManager defaultManager];
    isCanceled = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (self.isDownloading && activeURLConnection) {
        [activeURLConnection cancel];
        activeURLConnection = nil;
		if (![[NSUserDefaults standardUserDefaults] boolForKey:kMTSaveTmpFiles]) {
			[fm removeItemAtPath:decryptFilePath error:nil];
		}    }
    while (writingData){
        //Block until latest write data is complete - should stop quickly because isCanceled is set
    } //Wait for pipe out to complete
    [self cleanupFiles]; //Everything but the final file
    if(decrypterTask && [decrypterTask isRunning]) {
        [decrypterTask terminate];
    }
    if(encoderTask && [encoderTask isRunning]) {
        [encoderTask terminate];
    }
    if(commercialTask && [commercialTask isRunning]) {
        [commercialTask terminate];
    }
	
    if (encodeFileHandle) {
        [encodeFileHandle closeFile];
		if (![[NSUserDefaults standardUserDefaults] boolForKey:kMTSaveTmpFiles]) {
			[fm removeItemAtPath:_encodeFilePath error:nil];
		}
    }
    if ([_downloadStatus intValue] == kMTStatusEncoding || (_simultaneousEncode && self.isDownloading)) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationEncodeWasCanceled object:self];
    }
    if ([_downloadStatus intValue] == kMTStatusCaptioning) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationCaptionWasCanceled object:self];
    }
    if ([_downloadStatus intValue] == kMTStatusCommercialing) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationCommercialWasCanceled object:self];
    }
    [self setValue:[NSNumber numberWithInt:kMTStatusNew] forKeyPath:@"downloadStatus"];
    if (_processProgress != 0.0 ) {
		_processProgress = 0.0;
		[[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:self];
  	}
    
}

#pragma mark - Download/Conversion  Progress Tracking

-(void)checkStillActive
{
	if (previousProcessProgress == _processProgress) { //The process is stalled so cancel and restart
													   //Cancel and restart or delete depending on number of time we've been through this
        DDLogMajor (@"process stalled; rescheduling");
		[self rescheduleShowWithDecrementRetries:@(YES)];
	} else if ([self isInProgress]){
		previousProcessProgress = _processProgress;
		[self performSelector:@selector(checkStillActive) withObject:nil afterDelay:kMTProgressCheckDelay];
	}
    [previousCheck release];
    previousCheck = [[NSDate date] retain];
}


-(BOOL) isInProgress {
    return (!(self.isNew || self.isDone));
}

-(BOOL) isDownloading {
	return ([_downloadStatus intValue] == kMTStatusDownloading);
}

-(BOOL) isDone {
	int status = [_downloadStatus intValue];
	return (status == kMTStatusDone) ||
	(status == kMTStatusFailed) ||
	(status == kMTStatusDeleted);
}

-(BOOL) isNew {
	return ([_downloadStatus intValue] == kMTStatusNew);
}

-(void)updateProgress
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
}

#pragma mark - Video manipulation methods

-(NSURL *) URLExists: (NSString *) path {
	if (!path) return nil;
	path = [path stringByExpandingTildeInPath];
	if ([[NSFileManager defaultManager] fileExistsAtPath:path] ){
		return [NSURL fileURLWithPath: path];
	} else {
		return nil;
	}
}

-(NSURL *) videoFileURLWithEncrypted: (BOOL) encrypted {
	if (!self.isDone) return nil;
	NSURL *   URL =  [self URLExists: _encodeFilePath];
	if (!URL) URL= [self URLExists: decryptFilePath];
	if (!URL && encrypted) URL = [self URLExists: _downloadFilePath];
	return URL;
}

-(BOOL) canPlayVideo {
	return	self.isDone && [self videoFileURLWithEncrypted:NO];
}

-(BOOL) playVideo {
	if (self.isDone ) {
		NSURL * showURL =[self videoFileURLWithEncrypted:NO];
		if (showURL) {
			DDLogMajor(@"Playing video %@ ", showURL);
			return [[NSWorkspace sharedWorkspace] openURL:showURL];
		}
	}
	return NO;
}

-(BOOL) revealInFinder {
	NSURL * showURL =[self videoFileURLWithEncrypted:NO];
	if (showURL) {
		DDLogMajor(@"Revealing file %@ ", showURL);
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ showURL ]];
		return YES;
	}
	return NO;
}

#pragma mark - Misc Support Functions

-(void)rescheduleOnMain
{
	writingData = NO;
	[self performSelectorOnMainThread:@selector(rescheduleShowWithDecrementRetries:) withObject:@YES waitUntilDone:YES];
}

-(void)writeData
{
	//	writingData = YES;
	int chunkSize = 10000;
	int nchunks = 0;
	int chunkReleaseMemory = 10;
	unsigned long dataRead;
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSData *data = nil;
	if (!isCanceled) {
		@try {
			data = [bufferFileReadHandle readDataOfLength:chunkSize];
		}
		@catch (NSException *exception) {
			[self rescheduleOnMain];
			DDLogDetail(@"buffer read fail:%@; rescheduling", exception.reason);
			return;
		}
		@finally {
		}
	}
	pipingData = YES;
	if (!isCanceled){
		@try {
			[downloadFileHandle writeData:data];
		}
		@catch (NSException *exception) {
			[self rescheduleOnMain];
			DDLogDetail(@"download write fail: %@; rescheduling", exception.reason);
			return;
		}
		@finally {
		}
	}
	pipingData = NO;
	dataRead = data.length;
	while (dataRead == chunkSize && !isCanceled) {
		@try {
			data = [bufferFileReadHandle readDataOfLength:chunkSize];
		}
		@catch (NSException *exception) {
			[self rescheduleOnMain];
			DDLogDetail(@"buffer read fail2: %@; rescheduling", exception.reason);
			return;
		}
		@finally {
		}
		pipingData = YES;
		if (!isCanceled) {
			@try {
				[downloadFileHandle writeData:data];
			}
			@catch (NSException *exception) {
				[self rescheduleOnMain];
				DDLogDetail(@"download write fail2: %@; rescheduling", exception.reason);
				return;
			}
			@finally {
			}
		}
		pipingData = NO;
		if (isCanceled) break;
		dataRead = data.length;
		//		dataDownloaded += data.length;
		_processProgress = (double)[bufferFileReadHandle offsetInFile]/_show.fileSize;
        [self performSelectorOnMainThread:@selector(updateProgress) withObject:nil waitUntilDone:NO];
		nchunks++;
		if (nchunks == chunkReleaseMemory) {
			nchunks = 0;
			[pool drain];
			pool = [[NSAutoreleasePool alloc] init];
		}
	}
	[pool drain];
	if (!activeURLConnection || isCanceled) {
		DDLogDetail(@"Closing downloadFileHandle %@ which %@ from pipe1 for show %@", downloadFileHandle, (downloadFileHandle != [pipe1 fileHandleForWriting]) ? @"is not" : @"is", self.show.showTitle);
		[downloadFileHandle closeFile];
		DDLogDetail(@"closed filehandle");
		if (downloadFileHandle != [pipe1 fileHandleForWriting]) {
			[downloadFileHandle release];
		}
		downloadFileHandle = nil;
		[bufferFileReadHandle closeFile];
		[bufferFileReadHandle release];
		bufferFileReadHandle = nil;
		if (![[NSUserDefaults standardUserDefaults] boolForKey:kMTSaveTmpFiles]) {
			[[NSFileManager defaultManager] removeItemAtPath:_bufferFilePath error:nil];
		}
	}
	writingData = NO;
}

#pragma mark - NSURL Delegate Methods

-(void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    if (!_isSimultaneousEncoding) {
        [downloadFileHandle writeData:data];
        dataDownloaded += data.length;
        _processProgress = dataDownloaded/_show.fileSize;
        [[NSNotificationCenter defaultCenter] postNotificationName:kMTNotificationProgressUpdated object:nil];
		
    } else {
        [bufferFileWriteHandle writeData:data];
    }
	if (!writingData && _isSimultaneousEncoding) {
		writingData = YES;
		[self performSelectorInBackground:@selector(writeData) withObject:nil];
	}
}

- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace {
    return YES;
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge {
    //    [challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge];
    DDLogDetail(@"Show password check");
    [challenge.sender useCredential:[NSURLCredential credentialWithUser:@"tivo" password:self.show.tiVo.mediaKey persistence:NSURLCredentialPersistenceForSession] forAuthenticationChallenge:challenge];
    [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
}

-(void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    DDLogMajor(@"URL Connection Failed with error %@",error);
	[self rescheduleShowWithDecrementRetries:@(YES)];
}

#define kMTMinTiVoFileSize 100000
-(void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	double downloadedFileSize = 0;
	DDLogDetail(@"finished loading file");
    if (!_isSimultaneousEncoding) {
        downloadedFileSize = (double)[downloadFileHandle offsetInFile];
		[downloadFileHandle release];
        downloadFileHandle = nil;
		//Check to make sure a reasonable file size in case there was a problem.
		if (downloadedFileSize > kMTMinTiVoFileSize) {
			DDLogDetail(@"finished loading file");
			[self setValue:[NSNumber numberWithInt:kMTStatusDownloaded] forKeyPath:@"downloadStatus"];
			[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkStillActive) object:nil];
		}
    } else {
        downloadedFileSize = (double)[bufferFileWriteHandle offsetInFile];
        [bufferFileWriteHandle closeFile];
		//Check to make sure a reasonable file size in case there was a problem.
		if (downloadedFileSize > kMTMinTiVoFileSize) {
			DDLogDetail(@"finished loading simul encode file");
			[self setValue:[NSNumber numberWithInt:kMTStatusEncoding] forKeyPath:@"downloadStatus"];
			[self performSelector:@selector(trackDownloadEncode) withObject:nil afterDelay:0.3];
		}
    }
	downloadingURL = NO;
	activeURLConnection = nil;
	
    //Make sure to flush the last of the buffer file into the pipe and close it.
	if (!writingData && _isSimultaneousEncoding) {
		//		[self performSelectorInBackground:@selector(writeData) withObject:nil];
		writingData = YES;
		DDLogVerbose (@"writing last data for %@",self);
		[self writeData];
	}
	if (downloadedFileSize < kMTMinTiVoFileSize) { //Not a good download - reschedule
		NSString *dataReceived = [NSString stringWithContentsOfFile:_bufferFilePath encoding:NSUTF8StringEncoding error:nil];
		if (dataReceived) {
			NSRange noRecording = [dataReceived rangeOfString:@"recording not found" options:NSCaseInsensitiveSearch];
			if (noRecording.location != NSNotFound) { //This is a missing recording
				DDLogMajor(@"Deleted TiVo show; marking %@",self);
				self.downloadStatus = [NSNumber numberWithInt: kMTStatusDeleted];
				[self.show.tiVo updateShows:nil];
				return;
			}
		}
		DDLogMajor(@"Downloaded file  too small - rescheduling; File sent was %@",dataReceived);
		[self performSelector:@selector(rescheduleShowWithDecrementRetries:) withObject:@(NO) afterDelay:kMTTiVoAccessDelay];
	} else {
		self.show.fileSize = downloadedFileSize;  //More accurate file size
		NSNotification *not = [NSNotification notificationWithName:kMTNotificationDownloadDidFinish object:self.show.tiVo];
		[[NSNotificationCenter defaultCenter] performSelector:@selector(postNotification:) withObject:not afterDelay:4.0];
	}
}


#pragma mark Convenience methods

-(BOOL) canSimulEncode {
    return self.encodeFormat.canSimulEncode;
}

-(BOOL) shouldSimulEncode {
    return _simultaneousEncode;
}

-(BOOL) canSkipCommercials {
    return self.encodeFormat.comSkip.boolValue;
}

-(BOOL) shouldSkipCommercials {
    return _skipCommercials;
}

-(BOOL) canAddToiTunes {
    return self.encodeFormat.canAddToiTunes;
}

-(BOOL) shouldAddToiTunes {
    return _addToiTunesWhenEncoded;
}

#pragma mark - Custom Getters

-(NSNumber *)downloadIndex
{
	NSInteger index = [tiVoManager.downloadQueue indexOfObject:self];
	return [NSNumber numberWithInteger:index+1];
}


-(NSString *) showStatus {
	switch (_downloadStatus.intValue) {
		case  kMTStatusNew : return @"";
		case  kMTStatusDownloading : return @"Downloading";
		case  kMTStatusDownloaded : return @"Downloaded";
		case  kMTStatusDecrypting : return @"Decrypting";
		case  kMTStatusDecrypted : return @"Decrypted";
		case  kMTStatusCommercialing : return @"Detecting Commercials";
		case  kMTStatusCommercialed : return @"Commercials Detected";
		case  kMTStatusEncoding : return @"Encoding";
		case  kMTStatusDone : return @"Complete";
		case  kMTStatusCaptioned: return @"Subtitled";
		case  kMTStatusCaptioning: return @"Subtitling";
		case  kMTStatusDeleted : return @"TiVo Deleted";
		case  kMTStatusFailed : return @"Failed";
		default: return @"";
	}
}

-(void) setEncodeFormat:(MTFormat *) encodeFormat {
    if (_encodeFormat != encodeFormat ) {
        BOOL simulWasDisabled = ![self canSimulEncode];
        BOOL iTunesWasDisabled = ![self canAddToiTunes];
        BOOL skipWasDisabled = ![self canSkipCommercials];
        [_encodeFormat release];
        _encodeFormat = [encodeFormat retain];
        if (!self.canSimulEncode && self.shouldSimulEncode) {
            //no longer possible
            self.simultaneousEncode = NO;
        } else if (simulWasDisabled && [self canSimulEncode]) {
            //newly possible, so take user default
            self.simultaneousEncode = [[NSUserDefaults standardUserDefaults] boolForKey:kMTSimultaneousEncode];
        }
        if (!self.canAddToiTunes && self.shouldAddToiTunes) {
            //no longer possible
            self.addToiTunesWhenEncoded = NO;
        } else if (iTunesWasDisabled && [self canAddToiTunes]) {
            //newly possible, so take user default
            self.addToiTunesWhenEncoded = [[NSUserDefaults standardUserDefaults] boolForKey:kMTiTunesSubmit];
        }
        if (!self.canSkipCommercials && self.shouldSkipCommercials) {
            //no longer possible
            self.skipCommercials = NO;
        } else if (skipWasDisabled && [self canSkipCommercials]) {
            //newly possible, so take user default
            self.skipCommercials = [[NSUserDefaults standardUserDefaults] boolForKey:@"RunComSkip"];
        }
    }
}



#pragma mark - Memory Management

-(void)dealloc
{
    self.encodeFormat = nil;
	self.downloadDirectory = nil;
	if (_encodeFilePath) {
		[_encodeFilePath release];
        _encodeFilePath = nil;
	}
	if (_bufferFilePath) {
		[_bufferFilePath release];
        _bufferFilePath = nil;
	}
	if (_downloadFilePath) {
		[_downloadFilePath release];
        _downloadFilePath = nil;
	}
    [previousCheck release];
    [self deallocDownloadHandling];
	[self removeObserver:self forKeyPath:@"downloadStatus"];
	[super dealloc];
}

-(NSString *)description
{
    return [NSString stringWithFormat:@"%@ (%@)%@",self.show.showTitle,self.show.tiVoName,[self.show.protectedShow boolValue]?@"-Protected":@""];
}


@end

