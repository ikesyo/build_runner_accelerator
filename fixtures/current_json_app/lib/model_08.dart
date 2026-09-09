import 'package:json_annotation/json_annotation.dart';

part 'model_08.g.dart';

@JsonSerializable()
class Model08 {
  Model08({required this.id, required this.displayName});

  factory Model08.fromJson(Map<String, dynamic> json) =>
      _$Model08FromJson(json);

  final int id;
  final String displayName;

  Map<String, dynamic> toJson() => _$Model08ToJson(this);
}

// baseline-marker: base
