import 'package:json_annotation/json_annotation.dart';

part 'model_151.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model151 {
  const Model151({required this.id, required this.value});

  final int id;
  final String value;

  factory Model151.fromJson(Map<String, dynamic> json) =>
      _$Model151FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model151ToJson(this);
}
