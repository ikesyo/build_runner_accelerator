import 'package:json_annotation/json_annotation.dart';

part 'model_212.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model212 {
  const Model212({required this.id, required this.value});

  final int id;
  final String value;

  factory Model212.fromJson(Map<String, dynamic> json) =>
      _$Model212FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model212ToJson(this);
}
