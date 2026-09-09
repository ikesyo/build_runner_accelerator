import 'package:json_annotation/json_annotation.dart';

part 'model_02.g.dart';

@JsonSerializable()
class Model02 {
  Model02({required this.id, required this.displayName});

  factory Model02.fromJson(Map<String, dynamic> json) =>
      _$Model02FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model02ToJson(this);
}

// baseline-marker: base
