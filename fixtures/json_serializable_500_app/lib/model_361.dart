import 'package:json_annotation/json_annotation.dart';

part 'model_361.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model361 {
  const Model361({required this.id, required this.value});

  final int id;
  final String value;

  factory Model361.fromJson(Map<String, dynamic> json) =>
      _$Model361FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model361ToJson(this);
}
