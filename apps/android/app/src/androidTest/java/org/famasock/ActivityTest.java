package org.famasock;

import android.content.Intent;
import androidx.test.core.app.ActivityScenario;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class ActivityTest {
    @Test public void opensAndSurvivesRecreation() {
        try (ActivityScenario<MainActivity> activity = ActivityScenario.launch(MainActivity.class)) {
            activity.onActivity(a -> assertNotNull(a.findViewById(android.R.id.content)));
            activity.recreate();
            activity.onActivity(a -> assertFalse(a.isFinishing()));
        } finally {
            InstrumentationRegistry.getInstrumentation().getTargetContext().stopService(
                    new Intent(InstrumentationRegistry.getInstrumentation().getTargetContext(), NetworkService.class));
        }
    }
}
