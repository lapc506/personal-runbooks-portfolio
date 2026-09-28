using System;

namespace SafeDebloat;

// Toasts de resultado del apply (Microsoft.Windows.AppNotifications, ya referenciado vía WinAppSDK).
// Éxito -> Reminder, errores no críticos -> IM, error crítico -> Default.
// Un toast jamás debe tumbar el apply: todo va envuelto en try/catch.
public static class Notifier
{
    public enum Kind { Success, Partial, Critical }

    public static void Show(Kind kind, string title, string message)
    {
        try
        {
            var sound = kind switch
            {
                Kind.Success => Microsoft.Windows.AppNotifications.Builder.AppNotificationSoundEvent.Reminder,
                Kind.Partial => Microsoft.Windows.AppNotifications.Builder.AppNotificationSoundEvent.IM,
                _ => Microsoft.Windows.AppNotifications.Builder.AppNotificationSoundEvent.Default,
            };
            var notification = new Microsoft.Windows.AppNotifications.Builder.AppNotificationBuilder()
                .AddText(title)
                .AddText(message)
                .SetAudioEvent(sound)
                .SetTimeStamp(DateTime.Now)
                .BuildNotification();
            Microsoft.Windows.AppNotifications.AppNotificationManager.Default.Show(notification);
        }
        catch { }
    }
}
