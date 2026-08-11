########################################################################
# PROJECT: What separates "good" pitchers (top-25% ERA) from "bad" ones
#          (bottom-25% ERA), and are there distinct archetypes within
#          each group?
#
# Population: 120+ IP since 2025 (per Foolish Baseball's video cut)
# Author: Owen Quast
########################################################################


# =========================================================================
# 0. SETUP
# =========================================================================

# install.packages(c("tidyverse", "cluster", "factoextra", "broom",
#                     "httr2", "jsonlite"))

library(tidyverse)
library(cluster)      # clustering
library(factoextra)   # cluster visualization
library(broom)        # tidy model output
library(httr2)        # API requests
library(jsonlite)     # JSON parsing

set.seed(38)  

# Readable labels for every stat used below -- reused across every plot
# so the reader never has to decode a column name like "sw_str_pct".
var_labels <- c(
  k_pct         = "Strikeout %",
  bb_pct        = "Walk %",
  k_bb_pct      = "K% minus BB%",
  sw_str_pct    = "Swinging Strike %",
  o_swing_pct   = "Chase Rate (swings outside zone)",
  z_contact_pct = "Contact Rate on Pitches in Zone",
  hard_pct      = "Hard Contact % Allowed",
  barrel_pct    = "Barrel % Allowed",
  hardhit_pct   = "Hard-Hit % Allowed (95+ mph)",
  gb_pct        = "Ground Ball %",
  fbv           = "Fastball Velocity (mph)"
)

vars_to_check <- names(var_labels)


# =========================================================================
# 1. PULL DATA FROM FANGRAPHS
# =========================================================================
# NOTE: the CRAN version of baseballr::fg_pitcher_leaders() has a bug in
# its internal column-cleanup step that silently swallows real API
# errors. We pull and parse the same underlying API endpoint directly
# instead -- more code up front, but no dependency on a broken wrapper.

fetch_fg_pitchers <- function(startseason, endseason, qual, lg = "all", ind = "0") {
  url <- "https://www.fangraphs.com/api/leaders/major-league/data"
  
  resp <- request(url) %>%
    req_url_query(
      age = "", pos = "all", stats = "pit", lg = lg,
      qual = as.character(qual),
      season = as.character(endseason), season1 = as.character(startseason),
      startdate = "", enddate = "", month = "0", hand = "",
      team = "0", pageitems = "10000", pagenum = "1", ind = ind,
      rost = "0", players = "", type = "8", postseason = "",
      sortdir = "default", sortstat = "WAR"
    ) %>%
    req_perform()
  
  raw_json <- resp %>% resp_body_string() %>% fromJSON(flatten = TRUE)
  df <- as_tibble(raw_json$data)
  
  # FanGraphs returns column names like "K%" and "K-BB%" -- clean them
  # up the same way baseballr does internally.
  cn <- colnames(df)
  cn <- gsub("%", "_pct", cn, fixed = TRUE)
  cn <- gsub("/", "_", cn, fixed = TRUE)
  cn <- gsub(" ", "_", cn, fixed = TRUE)
  colnames(df) <- cn
  
  df
}

pitchers_raw <- fetch_fg_pitchers(
  startseason = 2025,
  endseason   = 2026,   # pulls 2025 + 2026-to-date, aggregated (ind="0")
  qual        = 120,    # minimum innings pitched
  lg          = "all",
  ind         = "0"
)

# Run these any time the pull changes -- FanGraphs' column names shift
# over time, and the select() call below depends on them matching.
# glimpse(pitchers_raw)
# colnames(pitchers_raw)


# =========================================================================
# 2. CLEAN INTO A WORKING TABLE
# =========================================================================
# "Name" and "Team" come back from the API as raw HTML anchor tags
# (e.g. '<a href="...">Sanchez</a>') -- strip_html() cleans those up.

strip_html <- function(x) gsub("<.*?>", "", x)

pitchers <- pitchers_raw %>%
  mutate(
    player_name = strip_html(Name),
    team_abbrev = strip_html(Team)
  ) %>%
  select(
    playerid = xMLBAMID, player_name, team_abbrev, age = Age,
    ip = IP, g = G, gs = GS, era = ERA, fip = FIP, xfip = xFIP, war = WAR,
    k_pct = K_pct, bb_pct = BB_pct, k_bb_pct = `K-BB_pct`,
    gb_pct = GB_pct, fb_pct = FB_pct, hr_fb = HR_FB,
    hard_pct = Hard_pct, barrel_pct = Barrel_pct, hardhit_pct = HardHit_pct,
    o_swing_pct = `O-Swing_pct`, z_contact_pct = `Z-Contact_pct`,
    sw_str_pct = SwStr_pct, fbv = FBv,
    # Skill-based grades (modeled off pitch characteristics/location,
    # NOT results) -- these let us test whether "unlucky" pitchers
    # actually have good-pitcher-caliber stuff/command, independent of
    # how their results actually turned out.
    stuff_plus = sp_stuff, location_plus = sp_location, pitching_plus = sp_pitching,
    pb_stuff = pb_stuff, pb_command = pb_command, pb_overall = pb_overall,
    # Per-pitch-type usage % and Stuff+ grades -- lets us see WHICH
    # pitches drive the overall grades above, and how many distinct
    # pitches each pitcher relies on.
    fb_usage = FB_pct1, sl_usage = SL_pct, ch_usage = CH_pct,
    cb_usage = CB_pct, ct_usage = CT_pct, sf_usage = SF_pct,
    fb_stuff = sp_s_FF, sl_stuff = sp_s_SL, ch_stuff = sp_s_CH,
    cb_stuff = sp_s_CU, ct_stuff = sp_s_FC, sf_stuff = sp_s_FS
  ) %>%
  filter(ip >= 120) %>%
  distinct(playerid, .keep_all = TRUE) %>%
  mutate(
    role = if_else(gs / g >= 0.5, "starter", "reliever"),
    # Count how many distinct pitches a guy throws at least 10% of the
    # time -- a simple arsenal-diversity score.
    arsenal_size = rowSums(across(ends_with("_usage"), ~ replace_na(.x, 0) >= 0.10))
  )

glimpse(pitchers)


# =========================================================================
# 3. LABEL GOOD / MIDDLE / BAD BY ERA
# =========================================================================

era_q <- quantile(pitchers$era, probs = c(0.25, 0.75), na.rm = TRUE)

pitchers <- pitchers %>%
  mutate(
    era_tier = case_when(
      era <= era_q[1] ~ "good",   # lower ERA = better pitching
      era >= era_q[2] ~ "bad",
      TRUE ~ "middle"
    ),
    era_tier = factor(era_tier, levels = c("bad", "middle", "good"))
  )

table(pitchers$era_tier)


# =========================================================================
# 4. VALIDATE AGAINST FOOLISH BAILEY'S NAMED LISTS (optional)
# =========================================================================
# Hand-keyed from the video screenshots. Mismatches are expected --
# he likely used a slightly different IP cutoff or endpoint date, and
# the "bad" screenshot was cut off at the bottom, so that list may be
# missing a couple of names.

good_list <- c(
  "Andrew Abbott", "Matthew Boyd", "Hunter Brown", "Kris Bubic",
  "Chase Burns", "Garrett Crochet", "Jacob deGrom", "Nathan Eovaldi",
  "Max Fried", "Logan Gilbert", "Tyler Glasnow", "Foster Griffin",
  "Clay Holmes", "Cade Horton", "Michael King", "Nolan McLean",
  "Parker Messick", "Max Meyer", "Jacob Misiorowski", "Casey Mize",
  "Shohei Ohtani", "Chad Patrick", "Nick Pivetta", "Quinn Priester",
  "Drew Rasmussen", "Carlos Rodon", "Trevor Rogers", "Joe Ryan",
  "Chris Sale", "Cristopher Sanchez", "Cam Schlittler", "Paul Skenes",
  "Tarik Skubal", "Ranger Suarez", "Logan Webb", "Zack Wheeler",
  "Gavin Williams", "Yoshinobu Yamamoto"
)

bad_list <- c(
  "Sandy Alcantara", "Spencer Arrighetti", "Walker Buehler", "Mike Burrows",
  "Griffin Canning", "Aaron Civale", "Bryce Elder", "Bailey Falter",
  "Erick Fedde", "Kyle Freeland", "Zac Gallen", "Kyle Hendricks",
  "Jake Irvin", "Janson Junk", "Jack Kochanowicz", "Jacob Lopez",
  "Michael Lorenzen", "German Marquez", "Dustin May", "Miles Mikolas",
  "Charlie Morton", "Aaron Nola", "Bailey Ober", "Chris Paddack",
  "Andre Pallante", "Mitchell Parker", "David Peterson", "Brandon Pfaadt",
  "Cal Quantrill", "Simeon Woods Richardson", "Kumar Rocker", "Roki Sasaki",
  "JP Sears", "Jeffrey Springs", "Spencer Strider", "Tomoyuki Sugano",
  "Taijuan Walker"
)

pitchers <- pitchers %>%
  mutate(
    in_video_good_list = player_name %in% good_list,
    in_video_bad_list  = player_name %in% bad_list
  )

# Rows where our ERA-cutoff tier disagrees with his named list:
pitchers %>%
  filter(era_tier == "good" & !in_video_good_list |
           era_tier != "good" & in_video_good_list) %>%
  select(player_name, era, era_tier, in_video_good_list)

pitchers %>%
  filter(era_tier == "bad" & !in_video_bad_list |
           era_tier != "bad" & in_video_bad_list) %>%
  select(player_name, era, era_tier, in_video_bad_list)


# =========================================================================
# 5. GOOD VS. BAD: WHERE DO THE DISTRIBUTIONS SEPARATE?
# =========================================================================

plot_boxplot_grid <- function(data, group_var, fill_values, title, subtitle = NULL) {
  data %>%
    select({{ group_var }}, all_of(vars_to_check)) %>%
    pivot_longer(-{{ group_var }}, names_to = "metric", values_to = "value") %>%
    ggplot(aes(x = {{ group_var }}, y = value, fill = {{ group_var }})) +
    geom_boxplot(outlier.alpha = 0.4) +
    facet_wrap(~metric, scales = "free_y",
               labeller = labeller(metric = var_labels)) +
    scale_fill_manual(values = fill_values) +
    theme_minimal(base_size = 11) +
    labs(title = title, subtitle = subtitle, x = NULL, y = NULL) +
    theme(legend.position = "none",
          strip.text = element_text(face = "bold", size = 8))
}

plot_boxplot_grid(
  data        = filter(pitchers, era_tier != "middle"),
  group_var   = era_tier,
  fill_values = c(bad = "#B33951", good = "#1B6B73"),
  title       = "Good (top-25% ERA) vs. Bad (bottom-25% ERA) Pitchers, 2025+",
  subtitle    = "120+ IP qualifiers -- each panel is one stat, boxes show the spread within each group"
)

# Read this as: the panel with the least overlap between the red and
# teal boxes is the single stat that best tells good and bad pitchers
# apart. (Spoiler: K% minus BB% usually wins by a wide margin.)


# =========================================================================
# 6. LOGISTIC REGRESSION: WHAT PREDICTS "GOOD"?
# =========================================================================
# k_bb_pct = k_pct - bb_pct by definition, so including all three
# together causes perfect multicollinearity. Keeping just k_bb_pct
# captures both signals without that problem.

reg_vars <- setdiff(vars_to_check, c("k_pct", "bb_pct"))

log_data <- pitchers %>%
  filter(era_tier != "middle") %>%
  mutate(is_good = if_else(era_tier == "good", 1, 0)) %>%
  select(is_good, all_of(reg_vars)) %>%
  drop_na()

log_model <- glm(is_good ~ ., data = log_data, family = "binomial")
summary(log_model)

tidy(log_model, exponentiate = TRUE, conf.int = TRUE) %>%
  mutate(stat = recode(term, !!!var_labels)) %>%
  select(stat, estimate, p.value, conf.low, conf.high) %>%
  arrange(p.value)

# estimate = odds ratio. A p.value under ~0.05 means that stat predicts
# "good" on its own, holding the others constant.


# =========================================================================
# 7. HELPER: CLUSTER A GROUP AND PLOT IT CLEARLY
# =========================================================================
# fviz_cluster()'s default output labels the axes "Dim1 (38.8%)" and
# "Dim2 (23.3%)" -- meaningless to anyone who doesn't know what PCA is.
# This wrapper relabels them and adds a caption explaining what the
# plot actually shows: pitchers who are similar across ALL the chosen
# stats end up near each other, even though there's no single stat on
# either axis.

cluster_group <- function(data, label_col, vars, k, plot_title) {
  clean <- data %>%
    select({{ label_col }}, all_of(vars)) %>%
    drop_na()
  
  scaled <- clean %>% select(-{{ label_col }}) %>% scale()
  rownames(scaled) <- clean[[as.character(substitute(label_col))]]
  
  km <- kmeans(scaled, centers = k, nstart = 25)
  clean$cluster <- factor(km$cluster)
  
  plot <- fviz_cluster(km, data = scaled, labelsize = 8, repel = TRUE) +
    theme_minimal() +
    labs(
      title = plot_title,
      subtitle = "Each point is a pitcher; distance = how different their overall statline is",
      x = "Pitching-style similarity -- axis 1",
      y = "Pitching-style similarity -- axis 2",
      caption = paste0(
        "Points are grouped from ", length(vars), " combined stats ",
        "(K%, BB%, contact quality, velocity, etc.), reduced to 2 dimensions ",
        "for plotting. Neither axis is a single real-world stat --\n",
        "what matters is which points cluster together, not their exact position."
      )
    ) +
    theme(plot.caption = element_text(hjust = 0, size = 8, color = "gray40"))
  
  list(data = clean, scaled = scaled, kmeans = km, plot = plot)
}

summarize_clusters <- function(clustered_data, vars) {
  clustered_data %>%
    group_by(cluster) %>%
    summarise(across(all_of(vars), ~ round(mean(.x, na.rm = TRUE), 3)),
              n = n(), .groups = "drop") %>%
    rename_with(~ var_labels[.x], .cols = all_of(vars))
}


# =========================================================================
# 8. ARCHETYPES WITHIN THE "GOOD" GROUP
# =========================================================================
# Excluding relievers by default: submarine/funk specialists (e.g.
# Tyler Rogers) have such an unusual profile that they show up as an
# outlier cluster of one and distort the geometry for everyone else.
# Set include_relievers <- TRUE to keep them in, or cluster them
# separately -- see Step 11.

include_relievers <- FALSE

good_pool <- pitchers %>%
  filter(era_tier == "good") %>%
  { if (include_relievers) . else filter(., role == "starter") }

# Check the elbow/silhouette plots before trusting k=2 below -- this is
# just what fit best on the last data pull.
fviz_nbclust(scale(select(good_pool, all_of(vars_to_check))), kmeans, method = "silhouette") +
  labs(title = "How many good-pitcher archetypes fit best?")

good_result <- cluster_group(
  data       = good_pool,
  label_col  = player_name,
  vars       = vars_to_check,
  k          = 2,
  plot_title = "Archetypes among top-25% ERA starters"
)

good_result$plot
summarize_clusters(good_result$data, vars_to_check)
good_result$data %>% arrange(cluster, player_name) %>% select(cluster, player_name)


# =========================================================================
# 9. ARCHETYPES WITHIN THE "BAD" GROUP
# =========================================================================

bad_pool <- pitchers %>%
  filter(era_tier == "bad") %>%
  { if (include_relievers) . else filter(., role == "starter") }

fviz_nbclust(scale(select(bad_pool, all_of(vars_to_check))), kmeans, method = "silhouette") +
  labs(title = "How many bad-pitcher archetypes fit best?")

bad_result <- cluster_group(
  data       = bad_pool,
  label_col  = player_name,
  vars       = vars_to_check,
  k          = 2,
  plot_title = "Archetypes among bottom-25% ERA starters"
)

bad_result$plot
summarize_clusters(bad_result$data, vars_to_check)
bad_result$data %>% arrange(cluster, player_name) %>% select(cluster, player_name)

# ERA vs. FIP/xFIP gap: a pitcher whose ERA is much worse than his FIP
# likely had bad defense/luck behind him rather than genuinely bad
# stuff -- a different story than a cluster where ERA and FIP agree.
pitchers %>%
  filter(era_tier == "bad", role == "starter") %>%
  mutate(era_fip_gap = round(era - fip, 2)) %>%
  select(player_name, era, fip, xfip, era_fip_gap) %>%
  arrange(desc(era_fip_gap))


# =========================================================================
# 10. ALL FOUR CLUSTERS SIDE BY SIDE
# =========================================================================
# Does the higher-K-BB%/lower-hard-contact "bad" cluster actually look
# statistically closer to the good clusters than to the other bad
# cluster? If so, that's evidence era_tier is conflating "genuinely
# below-average stuff" with "fine peripherals, bad luck or defense."

all_clusters <- bind_rows(
  good_result$data %>% mutate(group = paste0("good-", cluster)),
  bad_result$data  %>% mutate(group = paste0("bad-",  cluster))
) %>%
  mutate(group = factor(group, levels = c("good-1", "good-2", "bad-1", "bad-2")))

plot_boxplot_grid(
  data        = all_clusters,
  group_var   = group,
  fill_values = c("good-1" = "#1B6B73", "good-2" = "#5FA8AE",
                  "bad-1"  = "#E0A458", "bad-2"  = "#B33951"),
  title       = "All four archetype clusters side by side",
  subtitle    = "good-1/good-2 = two ways to pitch well | bad-1/bad-2 = two ways to pitch poorly"
) +
  theme(legend.position = "bottom", axis.text.x = element_blank())

# If a "bad" cluster's box sits closer to the good clusters than to the
# other bad cluster on stats like K% minus BB% or Hard Contact %, that
# cluster's pitchers likely have good/average underlying skill and got
# a bad ERA from something outside their control.


# =========================================================================
# 10b. IS "BAD-1" ACTUALLY GOOD STUFF THAT GOT UNLUCKY?
# =========================================================================
# The metrics above (K-BB%, hard contact, etc.) are still partly
# results-based -- a pitcher can post a good K-BB% and still have below-
# average command if hitters swing at bad pitches out of the zone. This
# section checks Stuff+/Location+/Pitching+ and PitchingBot's grades --
# metrics modeled off pitch characteristics and sequencing rather than
# outcomes -- to see if the "unlucky" cluster's underlying skill really
# does match the good clusters, or just looks that way in results.

skill_vars <- c("stuff_plus", "location_plus", "pitching_plus",
                "pb_stuff", "pb_command", "pb_overall")

skill_labels <- c(
  stuff_plus     = "Stuff+ (100 = average)",
  location_plus  = "Location+ (100 = average)",
  pitching_plus  = "Pitching+ (100 = average)",
  pb_stuff       = "PitchingBot Stuff Grade",
  pb_command     = "PitchingBot Command Grade",
  pb_overall     = "PitchingBot Overall Grade"
)

skill_comparison <- pitchers %>%
  filter(role == "starter") %>%
  left_join(
    bind_rows(
      good_result$data %>% select(player_name, cluster) %>% mutate(group = paste0("good-", cluster)),
      bad_result$data  %>% select(player_name, cluster) %>% mutate(group = paste0("bad-",  cluster))
    ) %>% select(player_name, group),
    by = "player_name"
  ) %>%
  filter(!is.na(group)) %>%
  mutate(group = factor(group, levels = c("good-1", "good-2", "bad-1", "bad-2")))

skill_comparison %>%
  select(group, all_of(skill_vars)) %>%
  pivot_longer(-group, names_to = "metric", values_to = "value") %>%
  ggplot(aes(x = group, y = value, fill = group)) +
  geom_boxplot(outlier.alpha = 0.4) +
  facet_wrap(~metric, scales = "free_y", labeller = labeller(metric = skill_labels)) +
  scale_fill_manual(values = c("good-1" = "#1B6B73", "good-2" = "#5FA8AE",
                               "bad-1"  = "#E0A458", "bad-2"  = "#B33951")) +
  theme_minimal(base_size = 11) +
  labs(title = "Skill-based grades: does bad-1 really have good-caliber stuff?",
       subtitle = "These grades are modeled off pitch quality/command, not results -- a fairer\ntest of 'unlucky' vs. 'genuinely below average' than outcome stats alone",
       x = NULL, y = NULL) +
  theme(legend.position = "bottom", axis.text.x = element_blank(),
        strip.text = element_text(face = "bold", size = 8))

# If bad-1's boxes land closer to good-1/good-2 than to bad-2 here too,
# that's strong, results-independent evidence they're bad-luck cases.
# If bad-1 actually grades out lower than good-1 on Stuff+/Location+
# despite similar outcome stats, that complicates the "just unlucky"
# story -- their K-BB%/contact numbers may be propped up by weaker
# competition, park effects, or a small-sample hot streak instead.

skill_comparison %>%
  group_by(group) %>%
  summarise(across(all_of(skill_vars), ~ round(mean(.x, na.rm = TRUE), 1)),
            n = n(), .groups = "drop") %>%
  rename_with(~ skill_labels[.x], .cols = all_of(skill_vars))


# =========================================================================
# 10c. DOES PITCH TYPE / ARSENAL EXPLAIN THE STUFF+ GAP?
# =========================================================================
# Stuff+ and PitchingBot's grades are themselves built by scoring each
# individual pitch type a guy throws, then blending those into one
# number -- so pitch characteristics are already baked into the overall
# grades from Step 10b. This section unpacks that blend: how many
# distinct pitches does each cluster rely on, and which specific pitch
# type is driving a cluster's Stuff+ up or down?

# Arsenal diversity: are contact-management pitchers (good-1) mixing in
# more distinct pitches than power pitchers (good-2), who may lean
# harder on 1-2 dominant weapons?
skill_comparison %>%
  group_by(group) %>%
  summarise(avg_arsenal_size = round(mean(arsenal_size, na.rm = TRUE), 2),
            n = n(), .groups = "drop")

# Per-pitch-type Stuff+ by cluster -- pivot long so each pitch type gets
# its own panel, same pattern as every other grid in this script.
pitch_stuff_labels <- c(
  fb_stuff = "Fastball Stuff+", sl_stuff = "Slider Stuff+",
  ch_stuff = "Changeup Stuff+", cb_stuff = "Curveball Stuff+",
  ct_stuff = "Cutter Stuff+", sf_stuff = "Splitter Stuff+"
)

skill_comparison %>%
  select(group, all_of(names(pitch_stuff_labels))) %>%
  pivot_longer(-group, names_to = "pitch", values_to = "value") %>%
  filter(!is.na(value)) %>%   # not every pitcher throws every pitch type
  ggplot(aes(x = group, y = value, fill = group)) +
  geom_boxplot(outlier.alpha = 0.4) +
  facet_wrap(~pitch, scales = "free_y", labeller = labeller(pitch = pitch_stuff_labels)) +
  scale_fill_manual(values = c("good-1" = "#1B6B73", "good-2" = "#5FA8AE",
                               "bad-1"  = "#E0A458", "bad-2"  = "#B33951")) +
  theme_minimal(base_size = 11) +
  labs(title = "Stuff+ grade by individual pitch type",
       subtitle = "Each panel only includes pitchers who throw that pitch -- sample sizes shrink accordingly",
       x = NULL, y = NULL) +
  theme(legend.position = "bottom", axis.text.x = element_blank(),
        strip.text = element_text(face = "bold", size = 8))

# Look for which pitch type shows the biggest gap between bad-1 and
# good-1 specifically -- that's the pitch most responsible for bad-1's
# lower overall Stuff+ from Step 10b. If it's concentrated in one pitch
# (e.g. a below-average slider) rather than spread evenly, that's a more
# fixable/specific problem than "generally worse stuff."


# =========================================================================
# 10d. IS AGE/DECLINE DOING REAL WORK WITHIN BAD-1?
# =========================================================================
# bad-1 includes some recognizable names in decline or coming off
# injury (Scherzer, Nola). Season-aggregate Stuff+/Location+ grades
# smooth over in-season decline -- a 38-year-old who lost velocity
# after the All-Star break still gets one blended number for the full
# year. This checks whether bad-1 skews older than the other clusters,
# and whether age correlates with how far a pitcher's Stuff+ trails
# good-1's within that cluster specifically.

skill_comparison %>%
  select(group, age) %>%
  pivot_longer(-group, names_to = "metric", values_to = "value") %>%
  ggplot(aes(x = group, y = value, fill = group)) +
  geom_boxplot(outlier.alpha = 0.4) +
  scale_fill_manual(values = c("good-1" = "#1B6B73", "good-2" = "#5FA8AE",
                               "bad-1"  = "#E0A458", "bad-2"  = "#B33951")) +
  theme_minimal(base_size = 11) +
  labs(title = "Age by cluster",
       subtitle = "If bad-1 skews notably older, age/decline may explain part of its Stuff+ gap from good-1",
       x = NULL, y = "Age") +
  theme(legend.position = "none")

# Within bad-1 specifically: does Stuff+ trail off with age, or is the
# below-average stuff spread evenly across young and old alike? A clean
# downward slope here would point at decline; a flat relationship would
# mean age isn't the driver and the Stuff+ gap needs a different
# explanation (e.g. never had elite stuff to begin with).
skill_comparison %>%
  filter(group == "bad-1") %>%
  select(player_name, age, era, fip, stuff_plus, location_plus) %>%
  arrange(desc(age))

# Quick correlation check (bad-1 only, small sample -- read loosely)
skill_comparison %>%
  filter(group == "bad-1") %>%
  summarise(age_stuff_cor = cor(age, stuff_plus, use = "complete.obs"))

