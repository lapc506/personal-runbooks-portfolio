# macOS Upgrade Reboot Deferral with Jamf Parameters Intel Macs.sh

_Works only when deploying this script using a policy for Intel-based Macs only._

## Corporate Client's Business Need

My client needs to implement silent distribution of [macOS Major Upgrades that get downloaded from Apple's servers directly](https://docs.jamf.com/technical-papers/jamf-pro/deploying-macos-upgrades/10.34.0/Downloading_a_macOS_Installer_Application_from_Apple.html), including [macOS Monterey](https://support.apple.com/en-us/HT212585) and [macOS Ventura](https://support.apple.com/en-us/HT213268).

My client also needs to get a solution that has a similar user experience (app behaviour as well as look-and-feel) to the [delayed reboots offered on the Deployment Policies for Windows endpoints administered with ManageEngine Endpoint Central](https://www.manageengine.com/products/desktop-central/help/configuring_desktop_central/configuring_deployment_templates.html).

![Deployment Policy Example - Delay Reboot](https://www.manageengine.com/products/desktop-central/help/images/deployment-policy-4.png)

These upgrades have to be pushed to MacBooks running with industry-common Intel processors, but also to those running the newest Apple Silicon processors (M1 / M1 Pro / M2 / M2 Pro).

I have suggested my client to use [Armin Briegel](https://www.linkedin.com/in/armin-briegel/)'s [SwiftUI app](https://scriptingosx.com/2021/06/download-full-installer/) called ["DownloadFullInstaller"](https://github.com/scriptingosx/DownloadFullInstaller) based on [William Smith](https://www.linkedin.com/in/talkingmoose/)'s recommendation on a Jamf technical webinar called ["Reinstall a Clean macOS with One Button"](https://www.youtube.com/watch?v=UtdPLbpREtM&t=549) at timestamp 9:09.

## Problem Statement

Previously, my client's IT Help Desk team had attempted to implement a legacy solution that involved [Preparing a macOS Installer Application as a DMG Built with **Jamf Composer**](https://docs.jamf.com/technical-papers/jamf-pro/deploying-macos-upgrades/10.34.0/Preparing_a_macOS_Installer_Application_as_a_DMG_built_with_Composer.html); however this solution has stopped working with the release of macOS Monterey.

Also, this solution was not compatible with the new release of [Apple MacBooks with Silicon processors](https://support.apple.com/en-us/HT211814) that would attempt upgrading to macOS Ventura or newer major upgrade versions.

## Solutions Previously Attempted

The initial solution I proposed was implementing a Jamf policy that could update a MacBook by pushing the full installers to any MacBook's Applications folder, and then offering an icon to the end user via the [Jamf Self Service App Catalog for macOS](https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Jamf_Self_Service_for_macOS.html) which would execute the installer upon double-clicking on it, whenever the end user was ready to upgrade and reboot their computer.

This solution worked perfectly fine with Intel-based MacBooks and it doesn't ask the end-user for any admin credentials.

However, for computers with Apple silicon (i.e., M1 chip), [these cannot be updated using a Jamf policy if a restart is required.](https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Running_Software_Update_Using_a_Policy.html)

Jamf has updated their documentation for Jamf Cloud version 10.43.0. In their technical article [Remote Commands for Computers](https://learn.jamf.com/bundle/jamf-pro-documentation-current/page/Remote_Commands_for_Computers.html), Jamf explains that manually pushing a Major Upgrade selecting the option **“Download/Download and Install Updates”** will allow deferral on the _update_ execution _(not deferring the reboot)_ when selecting the Install Action **“Download and allow macOS to install later”**.

Jamf also recommends that the **“Update OS version and built-in apps”** option must be selected, when sending this remote command via a mass action.
However, when using a mass action, _Jamf does not allow update deferrals **nor** reboot deferrals._

## Known Issues

When this script gets tested on Apple Silicon-based Macs, by executing a Jamf policy that includes it,
it is unavoidable that users get a prompt asking them for an administrator password.

This happens because [automated, non-interactive updates and upgrades on a Mac with Apple Silicon processor,
will only occur while authenticated using an MDM bootstrap token, starting macOS 11.2 or later, and the update being installed must be signed by Apple.](https://support.apple.com/guide/deployment/about-software-updates-depc4c80847a/web)

### Verifying that the Bootstrap Token has been escrowed into the MDM server

To have the update for computers with Apple silicon (i.e., M1 chip) installed automatically without user interaction,
a Bootstrap Token for target computers must be escrowed to the MDM solution server (e.g. Jamf Cloud or Jamf Pro on-premises).

According to official Apple Platform Deployment documentation, the technical article [About software updates for Apple devices](https://support.apple.com/guide/deployment/about-software-updates-depc4c80847a/web) on its section **"macOS software update or upgrade process"** states:

The `profiles` command-line tool has a number of options to interact with the bootstrap token:

* `sudo profiles install -type bootstraptoken`

  * This command generates a new bootstrap token and escrows it to the MDM solution. This command requires existing secure token administrator information to initially generate the bootstrap token and the MDM solution must support the feature.

* `sudo profiles remove -type bootstraptoken`

  * Removes the existing bootstrap token on the Mac and the MDM solution.

* `sudo profiles status -type bootstraptoken`

  * Reports back whether the MDM solution supports the bootstrap token feature, and what the current state of the bootstrap token is on the Mac.

* `sudo profiles validate -type bootstraptoken`

  * Reports back whether the MDM solution supports the bootstrap token feature, and what the current state of the bootstrap token is on the Mac
