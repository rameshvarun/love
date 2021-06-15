/**
 * Created by Martin Braun (Marty) for love2d
 *
 * This software is provided 'as-is', without any express or implied
 * warranty.  In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 **/

#include <stdio.h>
#include <string>
#include <tuple>
#include <vector>

// LOVE
#include "common/config.h"
#include "MobSvc.h"
#include "MobSvcDelegate.h"
#include "config_MobSvc.h"

#if defined(LOVE_MACOSX)
#include <CoreServices/CoreServices.h>
#elif defined(LOVE_IOS)
#include "common/ios.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>
#import <GameKit/GKLeaderboard.h>
#import <AudioToolbox/AudioServices.h>
#elif defined(LOVE_LINUX) || defined(LOVE_ANDROID)
#include <signal.h>
#include <sys/wait.h>
#include <errno.h>
#elif defined(LOVE_WINDOWS)
#include "common/utf8.h"
#include <shlobj.h>
#include <shellapi.h>
#pragma comment(lib, "shell32.lib")
#endif
#if defined(LOVE_ANDROID)
#include "common/android.h"
#elif defined(LOVE_LINUX)
#include <spawn.h>
#endif

// RICH
#include "common/richutil.h"

namespace love
{
	namespace mobsvc
	{
		GKLocalPlayer *mobSvcAccount;
		MobSvcDelegate *callbackDelegate;
		
		MobSvc::MobSvc()
		{
			callbackDelegate = [[MobSvcDelegate alloc] init];
		}
		
		void MobSvc::test() const
		{
			printf("MOBSVC_TEST\n");
		}
		
		std::string MobSvc::signInAwait()
		{
			__block bool wait = true;
			__block id playerAuthentificationDidChangeNotificationId = nil;
			
			mobSvcAccount = [GKLocalPlayer localPlayer];
			mobSvcAccount.authenticateHandler = ^(UIViewController *viewController, NSError *error __unused) {
				if(!mobSvcAccount.authenticated) {
					if(viewController != nil) {
						playerAuthentificationDidChangeNotificationId = [[NSNotificationCenter defaultCenter] addObserverForName:GKPlayerAuthenticationDidChangeNotificationName object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note __unused) { // triggers on GameCenter login
							wait = false;
						}];
						dispatch_async(dispatch_get_main_queue(), ^{ // run on UI thread
							UIViewController *self = this->getRootViewController();
							[self presentViewController:viewController animated:YES completion:nil]; // login view controller
						});
					} else {
						NSLog(@"Failed to attempt login into Game-Center: ViewController is nil.");
					}
				}
				else { // is logged in
					wait = false;
				}
			};
			
			while(wait) [NSThread sleepForTimeInterval:0.1]; // await, runs forever if the player won't login, because the login view controller does not provide any callbacks, there is just a playerAuthentificationDidChangeNotification that only triggers if the player logs in. This is why signIn must not be called more than once. Apple's GameKit policy disallows additional login attempts in any case.
			if(playerAuthentificationDidChangeNotificationId != nil) {
				[[NSNotificationCenter defaultCenter] removeObserver:playerAuthentificationDidChangeNotificationId];
			}
			if(mobSvcAccount.authenticated)
			{
				//[GKAchievement resetAchievementsWithCompletionHandler:^(NSError *error __unused){}]; // sim: reset all achievements (for debugging only)
				return std::string([mobSvcAccount.playerID UTF8String]);
			}
			return NULL;
		}
		
		bool MobSvc::isSignedIn()
		{
			return mobSvcAccount.authenticated;
		}
		
		void MobSvc::showAchievements()
		{
			GKGameCenterViewController *gameCenterController = [[GKGameCenterViewController alloc] init];
			if (gameCenterController != nil)
			{
				gameCenterController.gameCenterDelegate = callbackDelegate;
				gameCenterController.viewState = GKGameCenterViewControllerStateAchievements;
				gameCenterController.leaderboardTimeScope = GKLeaderboardTimeScopeToday;
				dispatch_async(dispatch_get_main_queue(), ^{ // run on UI thread
					UIViewController *self = this->getRootViewController();
					[self presentViewController:gameCenterController animated:YES completion:nil];
				});
			}
		}
		
		std::vector<bool> MobSvc::incrementAchievementProgressAwait(const char *achievementId, int steps, int maxSteps)
		{
			__block std::vector<bool> ret; ret.push_back(false); ret.push_back(false);
			
			if(mobSvcAccount.isAuthenticated)
			{
				__block bool wait = true;
				NSString *achievementIdentifier = [NSString stringWithUTF8String:achievementId];
				
				[GKAchievement loadAchievementsWithCompletionHandler:^(NSArray *achievements, NSError *error) {
					if (error != nil)
					{
						wait = false;
						NSLog(@"Failed to load achievements: %@", error);
					}
					GKAchievement *achievementReporter = nil;
					if (achievements != nil)
					{
						for (GKAchievement *achievement in achievements) {
							if ([achievement.identifier isEqualToString:achievementIdentifier]) {
								achievementReporter = achievement;
								break;
							}
						}
					}
					if(achievementReporter == nil) {
						achievementReporter = [[GKAchievement alloc] initWithIdentifier:achievementIdentifier];
					}
					achievementReporter.percentComplete += ((double)steps / (double)maxSteps) * 100;
					achievementReporter.showsCompletionBanner = NO;
					bool unlocked = false;
					if(achievementReporter.percentComplete >= 100.0) {
						unlocked = true;
						achievementReporter.percentComplete = 100.0;
					}
					[GKAchievement reportAchievements:@[achievementReporter] withCompletionHandler:^(NSError * _Nullable error) {
						//NSLog(@"### %lf", achievementReporter.percentComplete);
						if (!error) {
							ret[0] = true;
						} else {
							ret[0] = false;
							NSLog(@"Failed to increment achievement progress: %@", error);
						}
						ret[1] = unlocked;
						wait = false;
					}];
				}];
				
				while(wait) [NSThread sleepForTimeInterval:0.1]; // Await result
			}
			return ret;
		}
		
		UIViewController * MobSvc::getRootViewController()
		{
			static auto win = Module::getInstance<window::Window>(Module::M_WINDOW);
			
			SDL_Window *window = win-> getWindowObj();
			SDL_SysWMinfo systemWindowInfo;
			SDL_VERSION(&systemWindowInfo.version);
			if (!SDL_GetWindowWMInfo(window, &systemWindowInfo)) {
				printf("Error 0\n");
			}
			UIWindow * appWindow = systemWindowInfo.info.uikit.window;
			UIViewController * rootViewController = appWindow.rootViewController;
			
			return rootViewController;
		}
	}
}
