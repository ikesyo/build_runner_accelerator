import 'package:json_annotation/json_annotation.dart';

part 'model_255.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model255 {
  const Model255({required this.id, required this.value});

  final int id;
  final String value;

  factory Model255.fromJson(Map<String, dynamic> json) =>
      _$Model255FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model255ToJson(this);
}
