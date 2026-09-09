import 'package:json_annotation/json_annotation.dart';

part 'model_061.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model061 {
  const Model061({required this.id, required this.value});

  final int id;
  final String value;

  factory Model061.fromJson(Map<String, dynamic> json) =>
      _$Model061FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model061ToJson(this);
}
