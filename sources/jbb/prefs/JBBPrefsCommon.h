#import <Foundation/Foundation.h>

#define kJBBPrefsPath @"/var/mobile/Library/Preferences/com.pandan.jbb.cfg.plist"
#define kJBBLegacyPrefsPath @"/var/mobile/Library/Preferences/com.pandan.jbb.plist"
#define kJBBProfilesKey @"profiles"

NSString *JBBAppName(NSString *bundleID);
NSMutableDictionary *JBBLoadPrefs(void);
void JBBSavePrefs(NSMutableDictionary *prefs);
NSMutableDictionary *JBBProfile(NSMutableDictionary *prefs, NSString *bundleID, BOOL create);

NSArray *JBBAppsWithTweaks(void);
NSDictionary *JBBTweakMap(void);
BOOL JBBAppIsInstalled(NSString *bundleID);
NSInteger JBBInstalledAppCount(void);
NSUInteger JBBTweakFilterCount(void);
NSUInteger JBBTweakFilterFailedCount(void);
pid_t JBBFindPid(NSString *bundleID);
void JBBWaitForDaemonPublish(time_t since, NSTimeInterval timeout);
