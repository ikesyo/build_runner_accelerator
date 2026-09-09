import 'package:json_annotation/json_annotation.dart';

part 'model_047.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model047 {
  const Model047({required this.id, required this.value});

  final int id;
  final String value;

  factory Model047.fromJson(Map<String, dynamic> json) =>
      _$Model047FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model047ToJson(this);
}
