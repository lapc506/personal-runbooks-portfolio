#!/bin/bash

################ VARIABLES ################

JAMF_INPUT_OS_UPGRADE_VERSION="$4"
# For testing purposes:
# JAMF_INPUT_OS_UPGRADE_VERSION="$1"

JAMF_INPUT_OS_UPGRADE_INSTALLER_VERSION="$5"
# For testing purposes:
# JAMF_INPUT_OS_UPGRADE_INSTALLER_VERSION="$2"

JAMF_INPUT_DEFERRAL_ATTEMPTS="$6"
# For testing purposes:
# JAMF_INPUT_DEFERRAL_ATTEMPTS=3

JAMF_INPUT_INSTALLER_FILENAME="$7"
# For testing purposes:
# JAMF_INPUT_INSTALLER_FILENAME="Install macOS Monterey.app"

TIMEOUT_MINUTES=5

################ GLOBAL FUNCTIONS ################

getConsoleUsername()
{
    local _loggedInUser
    
    _loggedInUser=$(echo "show State:/Users/ConsoleUser" | scutil | awk '/Name :/ && ! /loginwindow/ { print $3 }')

    # An empty echo means no one is logged in.
    echo "${_loggedInUser}"
    # 'return' can only return a number.
    # Reference:
        # https://www.unix.com/shell-programming-and-scripting/146819-numeric-argument-required.html
    
    # OBSOLETE CODE: 
        # /usr/bin/python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser
        # user = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]
        # user = [user,""][user in [u"loginwindow", None, u""]]
        # print(user)'
    
    # SOURCES:
        # https://community.jamf.com/t5/jamf-pro/deferral-for-rebooting/m-p/189593
        # https://macmule.com/2014/11/19/how-to-get-the-currently-logged-in-user-in-a-more-apple-approved-way/ 

    # Why this code snippet stopped working:
        # https://www.jamf.com/blog/python2-is-gone-apple-macos/
        # https://erikberglund.github.io/2018/Get-the-currently-logged-in-user,-in-Bash/
        # https://scriptingosx.com/2022/03/macos-monterey-12-3-removes-python-2-link-collection/

    # How to replace this snippet:
        # https://scriptingosx.com/2019/09/get-current-user-in-shell-scripts-on-macos/
        # https://scriptingosx.com/2020/02/getting-the-current-user-in-macos-update/
        # https://scriptingosx.com/2021/11/the-unexpected-return-of-javascript-for-automation/
        # https://community.jamf.com/t5/jamf-pro/dep-notify-and-monterey-12-2-3-python-call/td-p/258488

}

TIMEOUT_MINUTES=5

promptRestartDialog_InitialAttempts()
{
    # "Prompting user if they want to restart"

	# Documentation Reference:
        # https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/DisplayDialogsandAlerts.html

    local _DialogBoxTitle _DialogBoxText _RestartNowButton _SkipButton _DialogResult

	_DialogBoxTitle="Apple Software Updates. Restart Required"
	_DialogBoxText="Your computer needs to install Apple software updates that require a restart to complete.\nPlease save all work and click Restart Now."
	_RestartNowButton="Restart Now"
	_Postpone1hourButton="Postpone 1 hour"
    _Postpone2hoursButton="Postpone 2 hours"

    _DialogResult=$(/usr/bin/osascript <<APPLESCRIPT_END
    tell application "System Events"
    activate
    set the answer to the button returned of (display dialog "$_DialogBoxText" with title "$_DialogBoxTitle" buttons {"$_Postpone2hoursButton","$_Postpone1hourButton","$_RestartNowButton"} default button "$_RestartNowButton")
    end tell
APPLESCRIPT_END
    )

    echo "${_DialogResult}"
}

promptRestartDialog_FinalAttempt()
{
    # "Prompting user if they want to restart"

	# Documentation Reference:
        # https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/DisplayDialogsandAlerts.html

    local _DialogBoxTitle _DialogBoxText _RestartNowButton _SkipButton _DialogResult

	_DialogBoxTitle="Apple Software Updates. Restart Required"
	_DialogBoxText="Your computer needs to install Apple software updates that require a restart to complete.\nPlease save all work and click Restart Now."
	_RestartNowButton="Restart Now"

    _DialogResult=$(/usr/bin/osascript <<APPLESCRIPT_END
    tell application "System Events"
    activate
    set the answer to the button returned of (display dialog "$_DialogBoxText" with title "$_DialogBoxTitle" buttons {"$_RestartNowButton"} default button "$_RestartNowButton")
    end tell
APPLESCRIPT_END
    )

    echo "${_DialogResult}"
}

displayRestartReminderNotification()
{
	# Documentation Reference:
    # https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/DisplayNotifications.html
    
    local _NotificationTitle _NotificationSubtitle _NotificationText _NotificationSoundName _NotificationResult

    echo " "
    echo "5. About to display a HUD notification letting the user know their MacBook is getting restarted in 2 minutes."

    _DialogResult=$(/usr/bin/osascript <<APPLESCRIPT_END
    tell application "System Events"
    activate
    display notification "Your system will get restarted in 2 minutes." with title "Apple Software Updates" subtitle "Restart Pending" sound name "Frog"
    end tell
APPLESCRIPT_END
    )
    
}

################ SCRIPT STARTS HERE ################
if [ ! -e "/Applications/$JAMF_INPUT_INSTALLER_FILENAME" ] ; then
    echo "$JAMF_INPUT_INSTALLER_FILENAME does not exist."
    echo "No restart is required."
else
    echo " "
    echo "1. Checking if Mac OS Upgrade installer version $JAMF_INPUT_OS_UPGRADE_INSTALLER_VERSION for OS version $JAMF_INPUT_OS_UPGRADE_VERSION exists and requires a restart."

    # Check if the cached installer version matches 17.4.01,
    # which is the .app file version for 12.4 installer.
    # Reference: https://mrmacintosh.com/macos-12-monterey-full-installer-database-download-directly-from-apple/

    MacOS_Cached_Installer_Version=$(plutil -p "/Applications/${JAMF_INPUT_INSTALLER_FILENAME}/Contents/Info.plist" | grep CFBundleShortVersionString)

    # Check with regex expression if the VersionString contains the Jamf Input string
    if [[ $MacOS_Cached_Installer_Version =~ .*"$JAMF_INPUT_OS_UPGRADE_INSTALLER_VERSION".* ]]; then

        echo " "
        echo "2. The Mac OS Upgrade installer version $JAMF_INPUT_OS_UPGRADE_INSTALLER_VERSION for OS version $JAMF_INPUT_OS_UPGRADE_VERSION DOES exist and has a pending restart."

        # Check if a user is logged in to be able to accept or decline the restart.
        # If no user is logged in, the updates __won't__ get installed without user approval.
        if [ -n "$(getConsoleUsername)" ]; then

            echo " "
            echo "3. The user $(getConsoleUsername) is logged in"

            echo " "
            echo "4. Prompt the user to accept the restart or postpone the updates, according to the deferral attempts input."

            for (( attempt=1 ; attempt<=JAMF_INPUT_DEFERRAL_ATTEMPTS ; attempt++ )); 
            do
                echo "---- Attempt #$attempt"

                if [ "$attempt" -ne $JAMF_INPUT_DEFERRAL_ATTEMPTS ]; then
                    restartMessageResult=$(promptRestartDialog_InitialAttempts)
                else
                    restartMessageResult=$(promptRestartDialog_FinalAttempt)
                fi

                if [ "$restartMessageResult" == "Postpone 1 hour" ]; then
                    TIMEOUT_MINUTES=60
                elif [ "$restartMessageResult" == "Postpone 2 hours" ]; then
                    TIMEOUT_MINUTES=120
                else
                    break
                fi

                echo "---- User clicked to ask again in $TIMEOUT_MINUTES minutes"

                for (( minute=1 ; minute<=TIMEOUT_MINUTES ; minute++ )); 
                do
                    echo "Sleeping for $minute minutes so far..."
                    # sleep 1
                    # sleep 60
                done
            done

            displayRestartReminderNotification
            # sleep 120

            # Execute startosinstall and delay rebooting for 2 minutes.
            echo " "
            echo "6. Here we should be executing >> ''/Applications/$JAMF_INPUT_INSTALLER_FILENAME/Contents/Resources/startosinstall'' --agreetolicense --rebootdelay 120 >> /var/log/startosinstall.log 2>&1"
            # "/Applications/$JAMF_INPUT_INSTALLER_FILENAME/Contents/Resources/startosinstall" --agreetolicense --rebootdelay 120 >> /var/log/startosinstall.log 2>&1

            # Install all updates with the --restart flag, if there are any updates require a restart        
            # echo "5. Here we should be executing >> /usr/sbin/softwareupdate --install --all --restart"
            # /usr/sbin/softwareupdate --install --all --restart

        # Log the fact that no user is logged in
        else
            echo " "
            echo "3. No one is logged in"
        fi
    else
        # Log the fact that no updates require a restart    
        echo "The cached installer version $MacOS_Cached_Installer_Version does not regex-match with $JAMF_INPUT_OS_UPGRADE_INSTALLER_VERSION"
        echo "No restart is required"
    fi
fi

exit 0
