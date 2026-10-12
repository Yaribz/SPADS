#!/usr/bin/env perl
#
# pod2html.pl: Custom POD to HTML converter made for SPADS plugin API
# documentation, with link anchors (AnchorJS), syntax highlighting
# (Prism) and responsive TOC placement.
#
# Copyright (C) 2026 Yann Riou <yaribzh@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

use warnings;
use strict;

use Getopt::Long;
use MetaCPAN::Pod::HTML;

my %opts;
GetOptions(
  \%opts,
  'css=s',
  'help',
  'index!',
  'infile=s',
  'outfile=s',
  'title=s',
    ) or do {
      displayUsage();
      exit 1;
      };

sub invalidParams {
  displayUsage();
  exit 1;
}

sub displayUsage {
  print <<"END_OF_USAGE";
Usage:  $0 --help --infile=<name> --outfile=<name>
           --index --noindex --css=<URL> --title=<name>
  --css           - stylesheet URL (default "pod2html.css")
  --help          - prints this message
  --[no]index     - generate an index at the top of the resulting html
                    (default behaviour)
  --infile        - filename for the pod to convert
                    (default: "SpadsPluginApi.pm")
  --outfile       - filename for the resulting html file
                    (default: "spadsPluginApiDoc.html")
  --title         - title that will appear in resulting html file
                    (default: "SPADS Plugin API Documentation")
END_OF_USAGE
}    

if(defined $opts{help}) {
  displayUsage();
  exit 0;
}

my $parser = MetaCPAN::Pod::HTML->new();

$parser->html_css($opts{css} // 'pod2html.css')
    unless(defined $opts{css} && $opts{css} eq '');

$parser->index($opts{index} // 1);

$parser->force_title($opts{title} // 'SPADS Plugin API Documentation')
    unless(defined $opts{title} && $opts{title} eq '');

$parser->html_header_tags(<<'HEADER_TAGS');
<meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-1" />
<script src="https://cdn.jsdelivr.net/npm/anchor-js/anchor.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/prismjs@1.30.0/components/prism-core.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/prismjs@1.30.0/plugins/autoloader/prism-autoloader.min.js"></script>
HEADER_TAGS

$parser->html_footer(<<'JAVASCRIPT');
<script>

  // Deep anchor links (AnchorJS)
  anchors.options.placement = 'left';
  anchors.add('h1,h2,dt');


  // Syntax highlighting (Prism)
  const codeBlocks = document.querySelectorAll('pre > code');

  let hasNonPerl = false;
  codeBlocks.forEach(function (code) {
    if (!/(?:^|\s)language-\S+/.test(code.className)) {
      code.classList.add('language-perl');
      return;
    }

    if (hasNonPerl)
      return;

    const languageClass = Array.from(code.classList).find(c => c.startsWith('language-'));
    const language = languageClass.substring('language-'.length);
    if (language !== 'perl')
      hasNonPerl = true;
  });

  if(hasNonPerl) {
    const languageNames = {
      perl: 'Perl',
      python: 'Python',
      bash: 'Bash'
    };
    codeBlocks.forEach(function (code) {
      const languageClass = Array.from(code.classList).find(c => c.startsWith('language-'));
      const language = languageClass.substring('language-'.length);
      const label = document.createElement('div');
      label.className = 'language-label language-' + language;
      label.textContent = languageNames[language] || language;
      code.parentElement.before(label);
    });
  }

  const toc = document.querySelector('body > nav');
  if(toc) {
    const totalTocWidth = toc.getBoundingClientRect().width + 17;
    const bodyMaxWidth = 1200 + 2 * 16;
    const threshold1 = totalTocWidth * 2 + bodyMaxWidth + 16;
    const threshold2 = totalTocWidth + bodyMaxWidth + 16;
    const style = document.createElement('style');
    style.textContent = `
@media (min-width: ${threshold2}px) and (max-width: ${threshold1}px) {
  body>nav {
    left: 8px;
    right: auto;
  }
  body {
    margin-left: ${totalTocWidth}px;
  }
}
@media (max-width: ${threshold2}px) {
  body>nav {
    position: static;
    margin-bottom: 40px;
  }
  body {
    margin-left: auto;
  }
}`;
    document.head.appendChild(style);
  }


  // Update current section in TOC
  const headings = Array.from(document.querySelectorAll('h1[id],h2[id]'));
  const tocLinks = Array.from(document.querySelectorAll('body > nav a[href^="#"]'));

  if (headings.length > 0) {
    let currentHeading = null;
    let currentLink = null;
    let scheduled = false;

    function updateCurrentHeading() {
      const activationLine = window.innerHeight / 7;
      let newHeading;

      const atTop = window.scrollY <= 1;
      const atBottom = window.scrollY + window.innerHeight >=  document.documentElement.scrollHeight - 1;
      if (atTop) {
        newHeading = headings[0];
      } else if (atBottom) {
        newHeading = headings[headings.length - 1];
      } else {
        newHeading = headings[0];
        for (const heading of headings) {
          if (heading.getBoundingClientRect().top > activationLine)
            break;
          newHeading = heading;
        }
      }

      if (newHeading !== currentHeading) {
        currentHeading = newHeading;
        const newLink = tocLinks.find(link => link.hash === '#' + currentHeading.id);
        if (currentLink)
          currentLink.classList.remove('current');
        if (newLink)
          newLink.classList.add('current');
        currentLink = newLink;
      }
    }

    function onScroll() {
      if (scheduled)
        return;
      scheduled = true;
      requestAnimationFrame(function () {
        scheduled = false;
        updateCurrentHeading();
      });
    }

    window.addEventListener('scroll', onScroll);
    window.addEventListener('resize', updateCurrentHeading);

    updateCurrentHeading();
  }

</script>
</body>
</html>
JAVASCRIPT

$parser->output_string(\my $html);
$parser->parse_file($opts{infile} // 'SpadsPluginApi.pm');

open(my $out,'>',$opts{outfile} // 'spadsPluginApiDoc.html')
    or die "Cannot open '$opts{outfile}': $!\n";
print $out $html;
close($out);
