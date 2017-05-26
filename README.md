4d-plugin-svg-converter
=======================

4D implementation of the rsvg program. 

### Platform

| carbon | cocoa | win32 | win64 |
|:------:|:-----:|:---------:|:---------:|
|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|<img src="https://cloud.githubusercontent.com/assets/1725068/22371562/1b091f0a-e4db-11e6-8458-8653954a7cce.png" width="24" height="24" />|

### Version

<img src="https://cloud.githubusercontent.com/assets/1725068/18940649/21945000-8645-11e6-86ed-4a0f800e5a73.png" width="32" height="32" /> <img src="https://cloud.githubusercontent.com/assets/1725068/18940648/2192ddba-8645-11e6-864d-6d5692d55717.png" width="32" height="32" />

## Syntax

```
error:=SVG Convert (svg;image;format;keyNames;keyValues;color;basePath)
```

Parameter|Type|Description
------------|------------|----
svg|PICTURE|
image|BLOB|
format|LONGINT|see Output Formats
keyNames|ARRAY LONGINT|see Converter Options
keyValues|ARRAY REAL|
color|TEXT|vackground color in CSS or ``none`` by default
basePath|TEXT|base URL (automatically converted; pass system path)
error|LONGINT|

```
error:=SVG Convert array (svg;image;format;keyNames;keyValues;color;basePath)
```

Parameter|Type|Description
------------|------------|----
svg|ARRAY PICTURE|
image|BLOB|each svg is a page in PDF
format|LONGINT|see Output Formats
keyNames|ARRAY LONGINT|either ``SVG Output PDF`` or ``SVG Output PS``
keyValues|ARRAY REAL|
color|TEXT|vackground color in CSS or ``none`` by default
basePath|TEXT|base URL (automatically converted; pass system path)
error|LONGINT|

* Output Formats

```c
SVG Output PDF (0)
SVG Output PNG (1)
SVG Output PS (2)
SVG Output SVG (3)
```

* SVG Converter Options

```c
SVG_DPI_X (1)
SVG_DPI_Y (2)
SVG_ZOOM_X (3)
SVG_ZOOM_Y (4)
SVG_ZOOM (5)
SVG_WIDTH (6)
SVG_HEIGHT (7)
SVG_KEEP_ASPECT_RATIO (8)
```

## Example

<img width="328" alt="2017-05-26 14 13 24" src="https://cloud.githubusercontent.com/assets/1725068/26481650/9575822a-421d-11e7-9980-b4613254bc1a.png">
