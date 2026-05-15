using System.Windows;

namespace WindowSharingClient;

public partial class App : Application
{
    private void App_Startup(object sender, StartupEventArgs e)
    {
        var splash = new SplashWindow();
        splash.Show();

        var main = new MainWindow();
        main.ContentRendered += (_, _) =>
        {
            splash.Close();
            main.Activate();
        };
        main.Show();
    }
}
