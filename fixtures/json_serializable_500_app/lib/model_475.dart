import 'package:json_annotation/json_annotation.dart';

part 'model_475.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model475 {
  const Model475({required this.id, required this.value});

  final int id;
  final String value;

  factory Model475.fromJson(Map<String, dynamic> json) =>
      _$Model475FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model475ToJson(this);
}
