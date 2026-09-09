import 'package:json_annotation/json_annotation.dart';

part 'model_01.g.dart';

@JsonSerializable()
class Model01 {
  Model01({required this.id, required this.displayName});

  factory Model01.fromJson(Map<String, dynamic> json) =>
      _$Model01FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model01ToJson(this);
}

// baseline-marker: base
